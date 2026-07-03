import { useEffect, useMemo, useRef, useState } from 'react';
import { useStore } from '../state/store';
import { getColumn, type Sample, type Panel } from '../state/types';
import { ancestorChain, getGateEventIndices, shapeContainsPoint } from '../gating/gateEval';
import { gatePercentages, collectQuadrantGroups, type QuadrantStat } from '../gating/gateStats';
import { ROOT_GATE_ID } from '../gating/gateTypes';
import type { GateShape, Point, QuadrantId } from '../gating/gateTypes';
import {
  makeScale,
  toRange,
  toDomain,
  niceTicks,
  logTicks,
  dataToPlotValue,
  plotValueToData,
  type LinearScale,
} from '../utils/scale';
import { densityColor, hexToRgba, COLORMAP_IDS, COLORMAP_LABELS, DEFAULT_COLORMAP, type ColormapId } from '../utils/colormap';
import { FONT_FAMILY_OPTIONS, MIN_FONT_SIZE, MAX_FONT_SIZE, DEFAULT_FONT_SIZE, resolvePanelFont } from '../utils/fonts';
import { marchingSquares, findLoopContainingPoint } from '../gating/contour';
import { GateNameDialog } from './GateNameDialog';

type Mode = 'none' | 'rectangle' | 'polygon' | 'range' | 'quadrant' | 'contour';

const DEFAULT_CONTOUR_THRESHOLD_PCT = 20;
const MIN_CONTOUR_THRESHOLD_PCT = 2;
const MAX_CONTOUR_THRESHOLD_PCT = 90;
const CONTOUR_THRESHOLD_STEP_PCT = 2;

const MARGIN = { top: 16, right: 20, bottom: 42, left: 58 };
const CLOSE_RADIUS_PX = 9;
const QUADRANT_LABEL_OFFSET = 6;
const QUADRANT_STATS_LINE_HEIGHT = 12;

function formatQuadrantStats(stat: QuadrantStat): string {
  return `${stat.count.toLocaleString()} (${stat.percentParent.toFixed(1)}%)`;
}
const DEFAULT_GATE_COLOR = '#2ee6a6';
const DEFAULT_HISTOGRAM_COLOR = '#4f8dff';
const SHAPE_MOVE_THRESHOLD_PX = 3;
const DEFAULT_STATS_ANNOTATION = { xFrac: 0.03, yFrac: 0.06 };
const ANNOTATION_PADDING = 6;
const ANNOTATION_LINE_HEIGHT = 13;

function clamp01(v: number): number {
  return Math.max(0, Math.min(1, v));
}

function paramRange(sample: Sample, name: string): number {
  return sample.parameters.find((p) => p.name === name)?.range ?? 1;
}

// ---- Editable-gate handle geometry (rectangle corners / polygon vertices / range edges) ----

type ShapeHandleKind =
  | { kind: 'rect-corner'; xField: 'x1' | 'x2'; yField: 'y1' | 'y2' }
  | { kind: 'polygon-vertex'; index: number }
  | { kind: 'range-edge'; field: 'min' | 'max' };

interface HandlePoint {
  handle: ShapeHandleKind;
  dataX: number;
  dataY: number | null; // null for range edges, which are drawn/hit-tested at a fixed pixel row
}

function getEditableShapeHandles(shape: GateShape): HandlePoint[] {
  if (shape.kind === 'rectangle') {
    return [
      { handle: { kind: 'rect-corner', xField: 'x1', yField: 'y1' }, dataX: shape.x1, dataY: shape.y1 },
      { handle: { kind: 'rect-corner', xField: 'x2', yField: 'y1' }, dataX: shape.x2, dataY: shape.y1 },
      { handle: { kind: 'rect-corner', xField: 'x1', yField: 'y2' }, dataX: shape.x1, dataY: shape.y2 },
      { handle: { kind: 'rect-corner', xField: 'x2', yField: 'y2' }, dataX: shape.x2, dataY: shape.y2 },
    ];
  }
  if (shape.kind === 'polygon') {
    return shape.points.map((p, index) => ({ handle: { kind: 'polygon-vertex', index }, dataX: p.x, dataY: p.y }));
  }
  if (shape.kind === 'range') {
    return [
      { handle: { kind: 'range-edge', field: 'min' }, dataX: shape.min, dataY: null },
      { handle: { kind: 'range-edge', field: 'max' }, dataX: shape.max, dataY: null },
    ];
  }
  return [];
}

function applyHandleDrag(shape: GateShape, handle: ShapeHandleKind, dataX: number, dataY: number): GateShape {
  if (shape.kind === 'rectangle' && handle.kind === 'rect-corner') {
    return { ...shape, [handle.xField]: dataX, [handle.yField]: dataY };
  }
  if (shape.kind === 'polygon' && handle.kind === 'polygon-vertex') {
    const points = shape.points.slice();
    points[handle.index] = { x: dataX, y: dataY };
    return { ...shape, points };
  }
  if (shape.kind === 'range' && handle.kind === 'range-edge') {
    return { ...shape, [handle.field]: dataX };
  }
  return shape;
}

function translateShape(shape: GateShape, dx: number, dy: number): GateShape {
  if (shape.kind === 'rectangle') {
    return { ...shape, x1: shape.x1 + dx, x2: shape.x2 + dx, y1: shape.y1 + dy, y2: shape.y2 + dy };
  }
  if (shape.kind === 'polygon') {
    return { ...shape, points: shape.points.map((p) => ({ x: p.x + dx, y: p.y + dy })) };
  }
  if (shape.kind === 'range') {
    return { ...shape, min: shape.min + dx, max: shape.max + dx };
  }
  return shape;
}

interface ShapeDragState {
  gateId: string;
  origShape: GateShape;
  kind: 'handle' | 'move';
  handle?: ShapeHandleKind;
  startData: Point;
  startPx: Point;
  moved: boolean;
}

interface Props {
  sample: Sample;
  panel: Panel;
  isFocused: boolean;
  onDragHandleDown: (e: React.MouseEvent) => void;
  onResizeHandleDown: (e: React.MouseEvent) => void;
}

export function GatePanel({
  sample,
  panel,
  isFocused,
  onDragHandleDown,
  onResizeHandleDown,
}: Props) {
  const {
    updatePanelAxis,
    updatePanelPlotType,
    updatePanelLogScale,
    updatePanelAxisLabel,
    addGate,
    addQuadrantGates,
    updateQuadrantPosition,
    addChildPanel,
    removePanel,
    renameGate,
    setGateColor,
    updateGateShape,
    addToLayout,
    updatePanelStatsAnnotationPos,
    updatePanelColormap,
    updatePanelFont,
  } = useStore();
  const rootRef = useRef<HTMLDivElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleValue, setTitleValue] = useState('');
  const [size, setSize] = useState({ width: 340, height: 230 });
  const [mode, setMode] = useState<Mode>('none');
  const [rectDraft, setRectDraft] = useState<{ x1: number; y1: number; x2: number; y2: number } | null>(null);
  const [rangeDraft, setRangeDraft] = useState<{ min: number; max: number } | null>(null);
  const [polyPoints, setPolyPoints] = useState<Point[]>([]);
  const [cursorData, setCursorData] = useState<Point | null>(null);
  const [quadrantDraft, setQuadrantDraft] = useState<Point | null>(null);
  const [draggingGroupId, setDraggingGroupId] = useState<string | null>(null);
  const [shapeDrag, setShapeDrag] = useState<ShapeDragState | null>(null);
  const [annotDrag, setAnnotDrag] = useState<{ startPx: Point; startFrac: { xFrac: number; yFrac: number } } | null>(null);
  const annotBoxRef = useRef<{ x: number; y: number; width: number; height: number } | null>(null);
  const suppressNextClick = useRef(false);
  const [pendingShape, setPendingShape] = useState<GateShape | null>(null);
  const [drawing, setDrawing] = useState(false);
  const [contourThresholdPct, setContourThresholdPct] = useState(DEFAULT_CONTOUR_THRESHOLD_PCT);
  const [contourPreviewPoints, setContourPreviewPoints] = useState<Point[] | null>(null);
  const lastCursorDataRef = useRef<Point | null>(null);

  const xLog = panel.xLogScale;
  const yLog = panel.plotType === 'scatter' && panel.yLogScale;
  const gateNode = sample.gates[panel.gateId];
  const path = useMemo(() => ancestorChain(sample.gates, panel.gateId), [sample.gates, panel.gateId]);

  useEffect(() => {
    if (isFocused) {
      rootRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'nearest' });
    }
  }, [isFocused]);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      const box = entries[0].contentRect;
      setSize({ width: Math.max(200, box.width), height: Math.max(160, box.height) });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') {
        setMode('none');
        setRectDraft(null);
        setRangeDraft(null);
        setPolyPoints([]);
        setQuadrantDraft(null);
        setPendingShape(null);
        setDrawing(false);
        setContourPreviewPoints(null);
      }
      if (e.key === 'Enter' && mode === 'polygon' && polyPoints.length >= 3) {
        setPendingShape({ kind: 'polygon', xParam: panel.xParam, yParam: panel.yParam, points: polyPoints });
      }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [mode, polyPoints, panel.xParam, panel.yParam]);

  // Reset any in-progress draw when the axes, plot type, or scale change.
  useEffect(() => {
    setMode('none');
    setRectDraft(null);
    setRangeDraft(null);
    setPolyPoints([]);
    setQuadrantDraft(null);
    setDraggingGroupId(null);
    setShapeDrag(null);
    setPendingShape(null);
    setDrawing(false);
    setContourPreviewPoints(null);
  }, [panel.xParam, panel.yParam, panel.plotType, xLog, yLog]);

  // Distinct quadrant-gate groups (crosshair placements) among this panel's own child gates,
  // each carrying its own count/%parent/%total alongside the name/color.
  const quadrantGroups = useMemo(
    () => collectQuadrantGroups(sample, gateNode, panel.xParam, panel.yParam),
    [sample, gateNode, panel.xParam, panel.yParam]
  );

  const indices = useMemo(() => getGateEventIndices(sample, panel.gateId), [sample, panel.gateId]);
  const { percentParent, percentTotal } = useMemo(
    () => gatePercentages(sample, gateNode, indices),
    [sample, gateNode, indices]
  );

  const plotWidth = size.width - MARGIN.left - MARGIN.right;
  const plotHeight = size.height - MARGIN.top - MARGIN.bottom;

  const xDomainMax = paramRange(sample, panel.xParam);
  const yDomainMax = panel.plotType === 'scatter' ? paramRange(sample, panel.yParam) : 0;

  const scaleX: LinearScale = useMemo(
    () =>
      makeScale(
        dataToPlotValue(xLog ? 1 : 0, xLog),
        dataToPlotValue(xDomainMax, xLog),
        MARGIN.left,
        MARGIN.left + plotWidth
      ),
    [xDomainMax, plotWidth, xLog]
  );

  const histogram = useMemo(() => {
    if (panel.plotType !== 'histogram') return null;
    const nBins = 150;
    const col = getColumn(sample, panel.xParam);
    const plotMin = dataToPlotValue(xLog ? 1 : 0, xLog);
    const plotMax = dataToPlotValue(xDomainMax, xLog);
    const span = plotMax - plotMin || 1;
    const counts = new Uint32Array(nBins);
    for (let i = 0; i < indices.length; i++) {
      const v = dataToPlotValue(col[indices[i]], xLog);
      let bin = Math.floor(((v - plotMin) / span) * nBins);
      if (bin < 0) bin = 0;
      if (bin >= nBins) bin = nBins - 1;
      counts[bin]++;
    }
    let max = 1;
    for (let b = 0; b < nBins; b++) if (counts[b] > max) max = counts[b];
    return { counts, nBins, max };
  }, [sample, panel.plotType, panel.xParam, indices, xDomainMax, xLog]);

  const scaleY: LinearScale = useMemo(() => {
    if (panel.plotType === 'histogram') {
      return makeScale(0, histogram?.max ?? 1, MARGIN.top + plotHeight, MARGIN.top);
    }
    return makeScale(
      dataToPlotValue(yLog ? 1 : 0, yLog),
      dataToPlotValue(yDomainMax, yLog),
      MARGIN.top + plotHeight,
      MARGIN.top
    );
  }, [panel.plotType, histogram, yDomainMax, plotHeight, yLog]);

  const xToPx = (raw: number) => toRange(scaleX, dataToPlotValue(raw, xLog));
  const pxToX = (px: number) => plotValueToData(toDomain(scaleX, px), xLog);
  const yToPx = (raw: number) => toRange(scaleY, dataToPlotValue(raw, yLog));
  const pxToY = (px: number) => plotValueToData(toDomain(scaleY, px), yLog);

  const densityGrid = useMemo(() => {
    if (panel.plotType !== 'scatter') return null;
    const gridN = 80;
    const xCol = getColumn(sample, panel.xParam);
    const yCol = getColumn(sample, panel.yParam);
    const xPlotMin = dataToPlotValue(xLog ? 1 : 0, xLog);
    const xSpan = dataToPlotValue(xDomainMax, xLog) - xPlotMin || 1;
    const yPlotMin = dataToPlotValue(yLog ? 1 : 0, yLog);
    const ySpan = dataToPlotValue(yDomainMax, yLog) - yPlotMin || 1;
    const counts = new Uint32Array(gridN * gridN);
    const binOf = new Int32Array(indices.length);
    for (let i = 0; i < indices.length; i++) {
      const idx = indices[i];
      let bx = Math.floor(((dataToPlotValue(xCol[idx], xLog) - xPlotMin) / xSpan) * gridN);
      let by = Math.floor(((dataToPlotValue(yCol[idx], yLog) - yPlotMin) / ySpan) * gridN);
      if (bx < 0) bx = 0;
      if (bx >= gridN) bx = gridN - 1;
      if (by < 0) by = 0;
      if (by >= gridN) by = gridN - 1;
      const bin = by * gridN + bx;
      binOf[i] = bin;
      counts[bin]++;
    }
    let maxCount = 1;
    for (let b = 0; b < counts.length; b++) if (counts[b] > maxCount) maxCount = counts[b];
    return { counts, binOf, maxCount, gridN, xPlotMin, xSpan, yPlotMin, ySpan };
  }, [sample, panel.plotType, panel.xParam, panel.yParam, indices, xDomainMax, yDomainMax, xLog, yLog]);

  // ---- Rendering ----
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = size.width * dpr;
    canvas.height = size.height * dpr;
    canvas.style.width = `${size.width}px`;
    canvas.style.height = `${size.height}px`;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = '#1a1b22';
    ctx.fillRect(0, 0, size.width, size.height);

    const { labelFont, tickFont } = resolvePanelFont(panel.fontFamily, panel.fontSize);

    ctx.strokeStyle = '#3a3f4b';
    ctx.lineWidth = 1;
    ctx.strokeRect(MARGIN.left, MARGIN.top, plotWidth, plotHeight);

    ctx.fillStyle = '#9aa4b2';
    ctx.font = tickFont;
    ctx.textAlign = 'center';
    const xTicks = xLog ? logTicks(xDomainMax) : niceTicks(0, xDomainMax);
    for (const t of xTicks) {
      const px = xToPx(t);
      ctx.beginPath();
      ctx.moveTo(px, MARGIN.top + plotHeight);
      ctx.lineTo(px, MARGIN.top + plotHeight + 4);
      ctx.stroke();
      ctx.fillText(formatTick(t), px, MARGIN.top + plotHeight + 14);
    }
    ctx.textAlign = 'right';
    const yTicks =
      panel.plotType === 'scatter' && yLog
        ? logTicks(yDomainMax)
        : niceTicks(0, panel.plotType === 'histogram' ? (histogram?.max ?? 1) : yDomainMax);
    for (const t of yTicks) {
      const py = panel.plotType === 'histogram' ? toRange(scaleY, t) : yToPx(t);
      ctx.beginPath();
      ctx.moveTo(MARGIN.left - 4, py);
      ctx.lineTo(MARGIN.left, py);
      ctx.stroke();
      ctx.fillText(formatTick(t), MARGIN.left - 7, py + 3);
    }
    ctx.textAlign = 'center';
    ctx.fillStyle = '#c7cdd6';
    ctx.font = labelFont;
    ctx.fillText((panel.xAxisLabel || panel.xParam) + (xLog ? ' (log)' : ''), MARGIN.left + plotWidth / 2, size.height - 6);
    ctx.save();
    ctx.translate(12, MARGIN.top + plotHeight / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.fillText(
      panel.plotType === 'histogram' ? 'Count' : (panel.yAxisLabel || panel.yParam) + (yLog ? ' (log)' : ''),
      0,
      0
    );
    ctx.restore();

    ctx.save();
    ctx.beginPath();
    ctx.rect(MARGIN.left, MARGIN.top, plotWidth, plotHeight);
    ctx.clip();

    const ownColor = gateNode?.color;
    if (panel.plotType === 'histogram' && histogram) {
      const binWidth = plotWidth / histogram.nBins;
      ctx.fillStyle = ownColor ?? DEFAULT_HISTOGRAM_COLOR;
      for (let b = 0; b < histogram.nBins; b++) {
        const c = histogram.counts[b];
        if (c === 0) continue;
        const x = MARGIN.left + b * binWidth;
        const yTop = toRange(scaleY, c);
        ctx.fillRect(x, yTop, Math.max(1, binWidth), MARGIN.top + plotHeight - yTop);
      }
    } else if (panel.plotType === 'scatter' && densityGrid) {
      const xCol = getColumn(sample, panel.xParam);
      const yCol = getColumn(sample, panel.yParam);
      if (ownColor) ctx.fillStyle = ownColor;
      for (let i = 0; i < indices.length; i++) {
        const idx = indices[i];
        const px = xToPx(xCol[idx]);
        const py = yToPx(yCol[idx]);
        if (!ownColor) {
          const count = densityGrid.counts[densityGrid.binOf[i]];
          const t = Math.log1p(count) / Math.log1p(densityGrid.maxCount);
          ctx.fillStyle = densityColor(t, panel.colormap ?? DEFAULT_COLORMAP);
        }
        ctx.fillRect(px - 1, py - 1, 2, 2);
      }
    }

    for (const childId of gateNode?.childIds ?? []) {
      const child = sample.gates[childId];
      const shape = child.shape;
      if (!shape) continue;
      if (shape.kind === 'range' && panel.plotType === 'histogram' && shape.param === panel.xParam) {
        drawRangeOverlay(ctx, xToPx, shape.min, shape.max, MARGIN.top, plotHeight, child.name, child.color ?? DEFAULT_GATE_COLOR, false);
        if (mode === 'none') drawEditHandles(ctx, xToPx, yToPx, shape, child.color ?? DEFAULT_GATE_COLOR);
      } else if (
        (shape.kind === 'rectangle' || shape.kind === 'polygon') &&
        panel.plotType === 'scatter' &&
        shape.xParam === panel.xParam &&
        shape.yParam === panel.yParam
      ) {
        drawShapeOverlay(ctx, xToPx, yToPx, shape, child.name, child.color ?? DEFAULT_GATE_COLOR, false);
        if (mode === 'none') drawEditHandles(ctx, xToPx, yToPx, shape, child.color ?? DEFAULT_GATE_COLOR);
      }
    }

    if (panel.plotType === 'scatter') {
      for (const group of quadrantGroups.values()) {
        drawQuadrantCrosshair(ctx, xToPx, yToPx, group.x, group.y, group.labels, group.colors, group.stats, false);
      }
    }

    if (mode === 'quadrant' && quadrantDraft) {
      drawQuadrantCrosshair(ctx, xToPx, yToPx, quadrantDraft.x, quadrantDraft.y, null, null, null, true);
    }

    if (mode === 'rectangle' && rectDraft) {
      drawShapeOverlay(
        ctx,
        xToPx,
        yToPx,
        { kind: 'rectangle', xParam: panel.xParam, yParam: panel.yParam, ...rectDraft },
        '',
        DEFAULT_GATE_COLOR,
        true
      );
    }
    if (mode === 'range' && rangeDraft) {
      drawRangeOverlay(ctx, xToPx, rangeDraft.min, rangeDraft.max, MARGIN.top, plotHeight, '', DEFAULT_GATE_COLOR, true);
    }
    if (mode === 'contour' && contourPreviewPoints && contourPreviewPoints.length >= 3) {
      drawShapeOverlay(
        ctx,
        xToPx,
        yToPx,
        { kind: 'polygon', xParam: panel.xParam, yParam: panel.yParam, points: contourPreviewPoints },
        '',
        DEFAULT_GATE_COLOR,
        true
      );
    }
    if (mode === 'polygon' && polyPoints.length > 0) {
      ctx.strokeStyle = '#ff9f1c';
      ctx.setLineDash([5, 3]);
      ctx.beginPath();
      polyPoints.forEach((p, i) => {
        const px = xToPx(p.x);
        const py = yToPx(p.y);
        if (i === 0) ctx.moveTo(px, py);
        else ctx.lineTo(px, py);
      });
      if (cursorData) {
        ctx.lineTo(xToPx(cursorData.x), yToPx(cursorData.y));
      }
      ctx.stroke();
      ctx.setLineDash([]);
      for (const p of polyPoints) {
        ctx.fillStyle = '#ff9f1c';
        ctx.beginPath();
        ctx.arc(xToPx(p.x), yToPx(p.y), 3, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    ctx.restore();

    drawStatsAnnotation(ctx);
  });

  function drawStatsAnnotation(ctx: CanvasRenderingContext2D) {
    const frac = panel.statsAnnotation ?? DEFAULT_STATS_ANNOTATION;
    const lines: string[] = [];
    if (panel.gateId !== ROOT_GATE_ID) lines.push(`${percentParent.toFixed(1)}% of parent`);
    lines.push(`${percentTotal.toFixed(1)}% of total`);
    ctx.font = resolvePanelFont(panel.fontFamily, panel.fontSize).tickFont;
    ctx.textAlign = 'left';
    const textWidth = Math.max(...lines.map((l) => ctx.measureText(l).width));
    const boxWidth = textWidth + ANNOTATION_PADDING * 2;
    const boxHeight = lines.length * ANNOTATION_LINE_HEIGHT + ANNOTATION_PADDING * 2 - 3;
    const maxX = Math.max(MARGIN.left, MARGIN.left + plotWidth - boxWidth);
    const maxY = Math.max(MARGIN.top, MARGIN.top + plotHeight - boxHeight);
    const x = Math.min(Math.max(MARGIN.left + frac.xFrac * plotWidth, MARGIN.left), maxX);
    const y = Math.min(Math.max(MARGIN.top + frac.yFrac * plotHeight, MARGIN.top), maxY);
    annotBoxRef.current = { x, y, width: boxWidth, height: boxHeight };

    ctx.fillStyle = 'rgba(10, 11, 15, 0.72)';
    ctx.strokeStyle = 'rgba(255,255,255,0.15)';
    ctx.lineWidth = 1;
    if (typeof ctx.roundRect === 'function') {
      ctx.beginPath();
      ctx.roundRect(x, y, boxWidth, boxHeight, 4);
      ctx.fill();
      ctx.stroke();
    } else {
      ctx.fillRect(x, y, boxWidth, boxHeight);
      ctx.strokeRect(x, y, boxWidth, boxHeight);
    }
    ctx.fillStyle = '#e5e7eb';
    lines.forEach((line, i) => {
      ctx.fillText(line, x + ANNOTATION_PADDING, y + ANNOTATION_PADDING + 9 + i * ANNOTATION_LINE_HEIGHT);
    });
  }

  function drawShapeOverlay(
    ctx: CanvasRenderingContext2D,
    xPx: (raw: number) => number,
    yPx: (raw: number) => number,
    shape: GateShape,
    label: string,
    color: string,
    isDraft: boolean
  ) {
    ctx.strokeStyle = isDraft ? '#ff9f1c' : color;
    ctx.lineWidth = 1.5;
    ctx.setLineDash(isDraft ? [5, 3] : []);
    let labelX = MARGIN.left;
    let labelY = MARGIN.top;
    if (shape.kind === 'rectangle') {
      const x1 = xPx(shape.x1);
      const x2 = xPx(shape.x2);
      const y1 = yPx(shape.y1);
      const y2 = yPx(shape.y2);
      ctx.strokeRect(Math.min(x1, x2), Math.min(y1, y2), Math.abs(x2 - x1), Math.abs(y2 - y1));
      labelX = Math.min(x1, x2) + 4;
      labelY = Math.min(y1, y2) + 12;
    } else if (shape.kind === 'polygon') {
      ctx.beginPath();
      shape.points.forEach((p, i) => {
        const px = xPx(p.x);
        const py = yPx(p.y);
        if (i === 0) ctx.moveTo(px, py);
        else ctx.lineTo(px, py);
      });
      ctx.closePath();
      ctx.stroke();
      if (shape.points[0]) {
        labelX = xPx(shape.points[0].x) + 4;
        labelY = yPx(shape.points[0].y) - 6;
      }
    }
    ctx.setLineDash([]);
    if (label) {
      ctx.fillStyle = isDraft ? '#ff9f1c' : color;
      ctx.font = resolvePanelFont(panel.fontFamily, panel.fontSize).tickFont;
      ctx.textAlign = 'left';
      ctx.fillText(label, labelX, labelY);
    }
  }

  function drawRangeOverlay(
    ctx: CanvasRenderingContext2D,
    xPx: (raw: number) => number,
    min: number,
    max: number,
    top: number,
    height: number,
    label: string,
    color: string,
    isDraft: boolean
  ) {
    const x1 = xPx(Math.min(min, max));
    const x2 = xPx(Math.max(min, max));
    ctx.fillStyle = isDraft ? 'rgba(255,159,28,0.15)' : hexToRgba(color, 0.12);
    ctx.fillRect(x1, top, x2 - x1, height);
    ctx.strokeStyle = isDraft ? '#ff9f1c' : color;
    ctx.setLineDash(isDraft ? [5, 3] : []);
    ctx.beginPath();
    ctx.moveTo(x1, top);
    ctx.lineTo(x1, top + height);
    ctx.moveTo(x2, top);
    ctx.lineTo(x2, top + height);
    ctx.stroke();
    ctx.setLineDash([]);
    if (label) {
      ctx.fillStyle = isDraft ? '#ff9f1c' : color;
      ctx.font = resolvePanelFont(panel.fontFamily, panel.fontSize).tickFont;
      ctx.textAlign = 'left';
      ctx.fillText(label, x1 + 3, top + 12);
    }
  }

  function drawQuadrantCrosshair(
    ctx: CanvasRenderingContext2D,
    xPx: (raw: number) => number,
    yPx: (raw: number) => number,
    x: number,
    y: number,
    labels: Partial<Record<QuadrantId, string>> | null,
    labelColors: Partial<Record<QuadrantId, string>> | null,
    stats: Partial<Record<QuadrantId, QuadrantStat>> | null,
    isDraft: boolean
  ) {
    const px = xPx(x);
    const py = yPx(y);
    ctx.strokeStyle = isDraft ? '#ff9f1c' : DEFAULT_GATE_COLOR;
    ctx.lineWidth = 1.25;
    ctx.setLineDash(isDraft ? [5, 3] : []);
    ctx.beginPath();
    ctx.moveTo(px, MARGIN.top);
    ctx.lineTo(px, MARGIN.top + plotHeight);
    ctx.moveTo(MARGIN.left, py);
    ctx.lineTo(MARGIN.left + plotWidth, py);
    ctx.stroke();
    ctx.setLineDash([]);
    if (labels) {
      ctx.font = resolvePanelFont(panel.fontFamily, panel.fontSize).tickFont;
      ctx.textAlign = 'right';
      if (labels.UL) {
        ctx.fillStyle = labelColors?.UL ?? DEFAULT_GATE_COLOR;
        ctx.fillText(labels.UL, px - QUADRANT_LABEL_OFFSET, MARGIN.top + 10);
        if (stats?.UL) ctx.fillText(formatQuadrantStats(stats.UL), px - QUADRANT_LABEL_OFFSET, MARGIN.top + 10 + QUADRANT_STATS_LINE_HEIGHT);
      }
      if (labels.LL) {
        ctx.fillStyle = labelColors?.LL ?? DEFAULT_GATE_COLOR;
        if (stats?.LL) ctx.fillText(formatQuadrantStats(stats.LL), px - QUADRANT_LABEL_OFFSET, MARGIN.top + plotHeight - 4 - QUADRANT_STATS_LINE_HEIGHT);
        ctx.fillText(labels.LL, px - QUADRANT_LABEL_OFFSET, MARGIN.top + plotHeight - 4);
      }
      ctx.textAlign = 'left';
      if (labels.UR) {
        ctx.fillStyle = labelColors?.UR ?? DEFAULT_GATE_COLOR;
        ctx.fillText(labels.UR, px + QUADRANT_LABEL_OFFSET, MARGIN.top + 10);
        if (stats?.UR) ctx.fillText(formatQuadrantStats(stats.UR), px + QUADRANT_LABEL_OFFSET, MARGIN.top + 10 + QUADRANT_STATS_LINE_HEIGHT);
      }
      if (labels.LR) {
        ctx.fillStyle = labelColors?.LR ?? DEFAULT_GATE_COLOR;
        if (stats?.LR) ctx.fillText(formatQuadrantStats(stats.LR), px + QUADRANT_LABEL_OFFSET, MARGIN.top + plotHeight - 4 - QUADRANT_STATS_LINE_HEIGHT);
        ctx.fillText(labels.LR, px + QUADRANT_LABEL_OFFSET, MARGIN.top + plotHeight - 4);
      }
    }
  }

  function drawEditHandles(
    ctx: CanvasRenderingContext2D,
    xPx: (raw: number) => number,
    yPx: (raw: number) => number,
    shape: GateShape,
    color: string
  ) {
    for (const hp of getEditableShapeHandles(shape)) {
      const px = xPx(hp.dataX);
      const py = hp.dataY !== null ? yPx(hp.dataY) : MARGIN.top + plotHeight / 2;
      ctx.beginPath();
      ctx.arc(px, py, 3.5, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
      ctx.strokeStyle = '#0b0c10';
      ctx.lineWidth = 1;
      ctx.stroke();
    }
  }

  function getMouseData(e: React.MouseEvent<HTMLCanvasElement>): Point {
    const rect = canvasRef.current!.getBoundingClientRect();
    const px = e.clientX - rect.left;
    const py = e.clientY - rect.top;
    return { x: pxToX(px), y: pxToY(py) };
  }

  function getMousePx(e: React.MouseEvent<HTMLCanvasElement>): Point {
    const rect = canvasRef.current!.getBoundingClientRect();
    return { x: e.clientX - rect.left, y: e.clientY - rect.top };
  }

  function findNearbyQuadrantGroup(e: React.MouseEvent<HTMLCanvasElement>): string | null {
    if (panel.plotType !== 'scatter') return null;
    const px = getMousePx(e);
    for (const [groupId, group] of quadrantGroups) {
      const gx = xToPx(group.x);
      const gy = yToPx(group.y);
      if (Math.hypot(px.x - gx, px.y - gy) <= CLOSE_RADIUS_PX + 3) return groupId;
    }
    return null;
  }

  function shapeMatchesPanelAxes(shape: GateShape): boolean {
    if (shape.kind === 'quadrant') return false;
    if (shape.kind === 'range') return panel.plotType === 'histogram' && shape.param === panel.xParam;
    return panel.plotType === 'scatter' && shape.xParam === panel.xParam && shape.yParam === panel.yParam;
  }

  // Finds an editable rectangle/polygon/range gate at the cursor: a nearby handle takes
  // priority (for reshaping), otherwise the shape's body (for moving it as a whole).
  function findEditableShapeAt(
    e: React.MouseEvent<HTMLCanvasElement>
  ): { gateId: string; shape: GateShape; handle?: ShapeHandleKind } | null {
    const px = getMousePx(e);
    const data = getMouseData(e);
    for (const childId of gateNode?.childIds ?? []) {
      const shape = sample.gates[childId]?.shape;
      if (!shape || !shapeMatchesPanelAxes(shape)) continue;
      for (const hp of getEditableShapeHandles(shape)) {
        const hx = xToPx(hp.dataX);
        const hy = hp.dataY !== null ? yToPx(hp.dataY) : MARGIN.top + plotHeight / 2;
        if (Math.hypot(px.x - hx, px.y - hy) <= CLOSE_RADIUS_PX) {
          return { gateId: childId, shape, handle: hp.handle };
        }
      }
    }
    for (const childId of gateNode?.childIds ?? []) {
      const shape = sample.gates[childId]?.shape;
      if (!shape || !shapeMatchesPanelAxes(shape)) continue;
      const testY = shape.kind === 'range' ? 0 : data.y;
      if (shapeContainsPoint(shape, data.x, testY)) {
        return { gateId: childId, shape };
      }
    }
    return null;
  }

  function isInAnnotationBox(px: Point): boolean {
    const box = annotBoxRef.current;
    if (!box) return false;
    return px.x >= box.x && px.x <= box.x + box.width && px.y >= box.y && px.y <= box.y + box.height;
  }

  function handleMouseDown(e: React.MouseEvent<HTMLCanvasElement>) {
    if (mode === 'none') {
      const px0 = getMousePx(e);
      if (isInAnnotationBox(px0)) {
        setAnnotDrag({ startPx: px0, startFrac: panel.statsAnnotation ?? DEFAULT_STATS_ANNOTATION });
        return;
      }
      const groupId = findNearbyQuadrantGroup(e);
      if (groupId) {
        setDraggingGroupId(groupId);
        return;
      }
      const hit = findEditableShapeAt(e);
      if (hit) {
        setShapeDrag({
          gateId: hit.gateId,
          origShape: hit.shape,
          kind: hit.handle ? 'handle' : 'move',
          handle: hit.handle,
          startData: getMouseData(e),
          startPx: getMousePx(e),
          moved: false,
        });
      }
      return;
    }
    const data = getMouseData(e);
    if (mode === 'rectangle') {
      setRectDraft({ x1: data.x, y1: data.y, x2: data.x, y2: data.y });
      setDrawing(true);
    } else if (mode === 'range') {
      setRangeDraft({ min: data.x, max: data.x });
      setDrawing(true);
    } else if (mode === 'quadrant') {
      setQuadrantDraft({ x: data.x, y: data.y });
      setDrawing(true);
    } else if (mode === 'polygon') {
      if (polyPoints.length >= 3) {
        const first = polyPoints[0];
        const firstPx = { x: xToPx(first.x), y: yToPx(first.y) };
        const px = getMousePx(e);
        const dist = Math.hypot(px.x - firstPx.x, px.y - firstPx.y);
        if (dist <= CLOSE_RADIUS_PX) {
          setPendingShape({ kind: 'polygon', xParam: panel.xParam, yParam: panel.yParam, points: polyPoints });
          return;
        }
      }
      setPolyPoints((pts) => [...pts, data]);
    } else if (mode === 'contour') {
      if (contourPreviewPoints && contourPreviewPoints.length >= 3) {
        setPendingShape({ kind: 'polygon', xParam: panel.xParam, yParam: panel.yParam, points: contourPreviewPoints });
      }
    }
  }

  // Traces the density contour loop under `data` at the given sensitivity, in data-space
  // coordinates, by running marching squares on the existing pseudocolor density grid.
  function computeContourAt(data: Point, thresholdPct: number): Point[] | null {
    if (!densityGrid) return null;
    const { gridN, xPlotMin, xSpan, yPlotMin, ySpan, counts, maxCount } = densityGrid;
    const gx = ((dataToPlotValue(data.x, xLog) - xPlotMin) / xSpan) * gridN;
    const gy = ((dataToPlotValue(data.y, yLog) - yPlotMin) / ySpan) * gridN;
    if (gx < 0 || gx > gridN || gy < 0 || gy > gridN) return null;
    const threshold = maxCount * (thresholdPct / 100);
    const loops = marchingSquares(counts, gridN, threshold);
    const loop = findLoopContainingPoint(loops, { x: gx, y: gy });
    if (!loop) return null;
    return loop.map((p) => ({
      x: plotValueToData(xPlotMin + (p.x / gridN) * xSpan, xLog),
      y: plotValueToData(yPlotMin + (p.y / gridN) * ySpan, yLog),
    }));
  }

  // Attached as a native (non-passive) listener so we can preventDefault() to stop the page
  // from scrolling while the user scrolls over the canvas to adjust contour sensitivity —
  // React's onWheel is passive by default and can't block the browser's scroll.
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || mode !== 'contour') return;
    function onWheel(e: WheelEvent) {
      e.preventDefault();
      const next = Math.max(
        MIN_CONTOUR_THRESHOLD_PCT,
        Math.min(MAX_CONTOUR_THRESHOLD_PCT, contourThresholdPct + (e.deltaY > 0 ? -CONTOUR_THRESHOLD_STEP_PCT : CONTOUR_THRESHOLD_STEP_PCT))
      );
      setContourThresholdPct(next);
      if (lastCursorDataRef.current) setContourPreviewPoints(computeContourAt(lastCursorDataRef.current, next));
    }
    canvas.addEventListener('wheel', onWheel, { passive: false });
    return () => canvas.removeEventListener('wheel', onWheel);
  });

  function handleMouseMove(e: React.MouseEvent<HTMLCanvasElement>) {
    if (annotDrag) {
      const px = getMousePx(e);
      if (plotWidth > 0 && plotHeight > 0) {
        const xFrac = clamp01(annotDrag.startFrac.xFrac + (px.x - annotDrag.startPx.x) / plotWidth);
        const yFrac = clamp01(annotDrag.startFrac.yFrac + (px.y - annotDrag.startPx.y) / plotHeight);
        updatePanelStatsAnnotationPos(sample.id, panel.id, xFrac, yFrac);
      }
      return;
    }
    if (draggingGroupId) {
      const data = getMouseData(e);
      updateQuadrantPosition(sample.id, draggingGroupId, data.x, data.y);
      return;
    }
    if (shapeDrag) {
      const px = getMousePx(e);
      const dist = Math.hypot(px.x - shapeDrag.startPx.x, px.y - shapeDrag.startPx.y);
      if (dist < SHAPE_MOVE_THRESHOLD_PX) return;
      const data = getMouseData(e);
      const nextShape =
        shapeDrag.kind === 'handle' && shapeDrag.handle
          ? applyHandleDrag(shapeDrag.origShape, shapeDrag.handle, data.x, data.y)
          : translateShape(shapeDrag.origShape, data.x - shapeDrag.startData.x, data.y - shapeDrag.startData.y);
      updateGateShape(sample.id, shapeDrag.gateId, nextShape);
      if (!shapeDrag.moved) setShapeDrag({ ...shapeDrag, moved: true });
      return;
    }
    if (mode === 'polygon' && polyPoints.length > 0) {
      setCursorData(getMouseData(e));
    }
    if (mode === 'contour') {
      const data = getMouseData(e);
      lastCursorDataRef.current = data;
      setContourPreviewPoints(computeContourAt(data, contourThresholdPct));
      return;
    }
    if (!drawing) return;
    const data = getMouseData(e);
    if (mode === 'rectangle' && rectDraft) {
      setRectDraft({ ...rectDraft, x2: data.x, y2: data.y });
    } else if (mode === 'range' && rangeDraft) {
      setRangeDraft({ ...rangeDraft, max: data.x });
    } else if (mode === 'quadrant') {
      setQuadrantDraft({ x: data.x, y: data.y });
    }
  }

  function handleMouseUp() {
    if (annotDrag) {
      setAnnotDrag(null);
      suppressNextClick.current = true;
      return;
    }
    if (draggingGroupId) {
      setDraggingGroupId(null);
      suppressNextClick.current = true;
      return;
    }
    if (shapeDrag) {
      if (shapeDrag.moved) suppressNextClick.current = true;
      setShapeDrag(null);
      return;
    }
    if (!drawing) return;
    setDrawing(false);
    if (mode === 'rectangle' && rectDraft) {
      if (Math.abs(rectDraft.x1 - rectDraft.x2) > 1e-6 && Math.abs(rectDraft.y1 - rectDraft.y2) > 1e-6) {
        setPendingShape({ kind: 'rectangle', xParam: panel.xParam, yParam: panel.yParam, ...rectDraft });
      } else {
        setRectDraft(null);
      }
    } else if (mode === 'range' && rangeDraft) {
      if (Math.abs(rangeDraft.min - rangeDraft.max) > 1e-6) {
        setPendingShape({ kind: 'range', param: panel.xParam, min: rangeDraft.min, max: rangeDraft.max });
      } else {
        setRangeDraft(null);
      }
    } else if (mode === 'quadrant' && quadrantDraft) {
      addQuadrantGates(sample.id, panel.gateId, panel.xParam, panel.yParam, quadrantDraft.x, quadrantDraft.y);
      setQuadrantDraft(null);
      setMode('none');
    }
  }

  function handleDoubleClick() {
    if (mode === 'polygon' && polyPoints.length >= 3) {
      setPendingShape({ kind: 'polygon', xParam: panel.xParam, yParam: panel.yParam, points: polyPoints });
    }
  }

  // Clicking directly on an existing child gate's shape (outside of drawing mode) drills down,
  // opening (or focusing) a brand-new panel for that population.
  function handleClick(e: React.MouseEvent<HTMLCanvasElement>) {
    if (suppressNextClick.current) {
      suppressNextClick.current = false;
      return;
    }
    if (mode !== 'none') return;
    const data = getMouseData(e);
    for (const childId of gateNode?.childIds ?? []) {
      const child = sample.gates[childId];
      const shape = child.shape;
      if (!shape) continue;
      if (panel.plotType === 'histogram' && shape.kind === 'range' && shape.param === panel.xParam) {
        if (shapeContainsPoint(shape, data.x, 0)) {
          addChildPanel(sample.id, panel.id, childId);
          return;
        }
      } else if (
        panel.plotType === 'scatter' &&
        shape.kind !== 'range' &&
        shape.xParam === panel.xParam &&
        shape.yParam === panel.yParam
      ) {
        if (shapeContainsPoint(shape, data.x, data.y)) {
          addChildPanel(sample.id, panel.id, childId);
          return;
        }
      }
    }
  }

  function confirmGate(name: string) {
    if (!pendingShape) return;
    addGate(sample.id, panel.gateId, name, pendingShape);
    setPendingShape(null);
    setRectDraft(null);
    setRangeDraft(null);
    setPolyPoints([]);
    setMode('none');
  }

  const params = sample.parameters;

  return (
    <div
      ref={rootRef}
      className={`gate-panel ${isFocused ? 'gate-panel-focused' : ''}`}
      style={{ left: panel.x, top: panel.y, width: panel.width, height: panel.height }}
    >
      <div className="gate-panel-header" onMouseDown={onDragHandleDown}>
        {panel.gateId !== ROOT_GATE_ID && (
          <span className="gate-color-swatch-wrap" onMouseDown={(e) => e.stopPropagation()}>
            <input
              type="color"
              className="gate-color-swatch"
              title="Set population color"
              value={gateNode?.color ?? '#2ee6a6'}
              onChange={(e) => setGateColor(sample.id, panel.gateId, e.target.value)}
            />
            {gateNode?.color && (
              <button
                className="gate-color-clear"
                title="Reset to default color"
                onClick={() => setGateColor(sample.id, panel.gateId, null)}
              >
                ×
              </button>
            )}
          </span>
        )}
        {editingTitle ? (
          <input
            autoFocus
            className="gate-panel-title-input"
            value={titleValue}
            onMouseDown={(e) => e.stopPropagation()}
            onChange={(e) => setTitleValue(e.target.value)}
            onBlur={() => {
              if (titleValue.trim()) renameGate(sample.id, panel.gateId, titleValue.trim());
              setEditingTitle(false);
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                if (titleValue.trim()) renameGate(sample.id, panel.gateId, titleValue.trim());
                setEditingTitle(false);
              }
              if (e.key === 'Escape') setEditingTitle(false);
            }}
          />
        ) : (
          <span
            className="gate-panel-title"
            title={
              panel.gateId === ROOT_GATE_ID
                ? path.map((n) => n.name).join(' › ')
                : `${path.map((n) => n.name).join(' › ')} (double-click to rename)`
            }
            onDoubleClick={(e) => {
              e.stopPropagation();
              if (panel.gateId === ROOT_GATE_ID) return;
              setTitleValue(gateNode?.name ?? '');
              setEditingTitle(true);
            }}
          >
            {gateNode?.name ?? 'Population'}
          </span>
        )}
        <button
          className="gate-panel-layout-btn"
          title="Add this panel to the Layout collage"
          onMouseDown={(e) => e.stopPropagation()}
          onClick={() => addToLayout(sample.id, panel.id)}
        >
          ⊞
        </button>
        <button
          className="gate-panel-close"
          title="Close this panel"
          onMouseDown={(e) => e.stopPropagation()}
          onClick={() => removePanel(sample.id, panel.id)}
        >
          ×
        </button>
      </div>
      <div className="gate-panel-path">{path.map((n) => n.name).join(' › ')}</div>
      <div className="plot-toolbar">
        <label>
          X:
          <select value={panel.xParam} onChange={(e) => updatePanelAxis(sample.id, panel.id, 'xParam', e.target.value)}>
            {params.map((p) => (
              <option key={p.name} value={p.name}>
                {p.label !== p.name ? `${p.name} (${p.label})` : p.name}
              </option>
            ))}
          </select>
        </label>
        <input
          className="axis-label-input"
          type="text"
          placeholder={panel.xParam}
          value={panel.xAxisLabel ?? ''}
          title="Custom X axis label (e.g. type GFP to replace the laser name)"
          onChange={(e) => updatePanelAxisLabel(sample.id, panel.id, 'xAxisLabel', e.target.value || null)}
        />
        <button
          className={`btn btn-small ${xLog ? 'btn-active' : ''}`}
          title="Toggle logarithmic X axis"
          onClick={() => updatePanelLogScale(sample.id, panel.id, 'xLogScale', !panel.xLogScale)}
        >
          log X
        </button>
        {panel.plotType === 'scatter' && (
          <>
            <label>
              Y:
              <select value={panel.yParam} onChange={(e) => updatePanelAxis(sample.id, panel.id, 'yParam', e.target.value)}>
                {params.map((p) => (
                  <option key={p.name} value={p.name}>
                    {p.label !== p.name ? `${p.name} (${p.label})` : p.name}
                  </option>
                ))}
              </select>
            </label>
            <input
              className="axis-label-input"
              type="text"
              placeholder={panel.yParam}
              value={panel.yAxisLabel ?? ''}
              title="Custom Y axis label (e.g. type BFP to replace the laser name)"
              onChange={(e) => updatePanelAxisLabel(sample.id, panel.id, 'yAxisLabel', e.target.value || null)}
            />
            <button
              className={`btn btn-small ${yLog ? 'btn-active' : ''}`}
              title="Toggle logarithmic Y axis"
              onClick={() => updatePanelLogScale(sample.id, panel.id, 'yLogScale', !panel.yLogScale)}
            >
              log Y
            </button>
          </>
        )}
      </div>
      <div className="plot-toolbar">
        <div className="btn-group">
          <button
            className={`btn btn-small ${panel.plotType === 'scatter' ? 'btn-active' : ''}`}
            onClick={() => updatePanelPlotType(sample.id, panel.id, 'scatter')}
          >
            Dot plot
          </button>
          <button
            className={`btn btn-small ${panel.plotType === 'histogram' ? 'btn-active' : ''}`}
            onClick={() => updatePanelPlotType(sample.id, panel.id, 'histogram')}
          >
            Histogram
          </button>
        </div>
        <div className="btn-group">
          {panel.plotType === 'scatter' ? (
            <>
              <button
                className={`btn btn-small ${mode === 'rectangle' ? 'btn-active' : ''}`}
                onClick={() => setMode(mode === 'rectangle' ? 'none' : 'rectangle')}
              >
                ▭
              </button>
              <button
                className={`btn btn-small ${mode === 'polygon' ? 'btn-active' : ''}`}
                onClick={() => setMode(mode === 'polygon' ? 'none' : 'polygon')}
              >
                ⬠
              </button>
              <button
                className={`btn btn-small ${mode === 'quadrant' ? 'btn-active' : ''}`}
                title="Quadrant gate: click-drag to place a crosshair, splitting the plot into 4 populations"
                onClick={() => setMode(mode === 'quadrant' ? 'none' : 'quadrant')}
              >
                ✛
              </button>
              <button
                className={`btn btn-small ${mode === 'contour' ? 'btn-active' : ''}`}
                title="Contour gate: hover a density region to preview its outline, scroll to adjust sensitivity, click to create the gate"
                onClick={() => setMode(mode === 'contour' ? 'none' : 'contour')}
              >
                ≈
              </button>
            </>
          ) : (
            <button
              className={`btn btn-small ${mode === 'range' ? 'btn-active' : ''}`}
              onClick={() => setMode(mode === 'range' ? 'none' : 'range')}
            >
              ↔
            </button>
          )}
          {mode !== 'none' && (
            <button
              className="btn btn-small"
              onClick={() => {
                setMode('none');
                setRectDraft(null);
                setRangeDraft(null);
                setPolyPoints([]);
                setQuadrantDraft(null);
                setContourPreviewPoints(null);
              }}
            >
              Cancel
            </button>
          )}
        </div>
        <span className="event-count">{indices.length.toLocaleString()}</span>
      </div>
      <div className="plot-toolbar">
        {panel.plotType === 'scatter' && (
          <label>
            Colors:
            <select
              value={panel.colormap ?? DEFAULT_COLORMAP}
              onChange={(e) => updatePanelColormap(sample.id, panel.id, e.target.value as ColormapId)}
            >
              {COLORMAP_IDS.map((id) => (
                <option key={id} value={id}>
                  {COLORMAP_LABELS[id]}
                </option>
              ))}
            </select>
          </label>
        )}
        <label>
          Font:
          <select
            value={panel.fontFamily ?? FONT_FAMILY_OPTIONS[0].id}
            onChange={(e) => updatePanelFont(sample.id, panel.id, e.target.value, panel.fontSize ?? null)}
          >
            {FONT_FAMILY_OPTIONS.map((f) => (
              <option key={f.id} value={f.id}>
                {f.label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Size:
          <input
            type="number"
            className="font-size-input"
            min={MIN_FONT_SIZE}
            max={MAX_FONT_SIZE}
            value={panel.fontSize ?? DEFAULT_FONT_SIZE}
            onChange={(e) => updatePanelFont(sample.id, panel.id, panel.fontFamily ?? null, Number(e.target.value))}
          />
        </label>
      </div>
      {mode === 'polygon' && (
        <div className="hint">Click vertices; click near the first, dbl-click, or Enter to close.</div>
      )}
      {mode === 'quadrant' && <div className="hint">Click-drag to place the crosshair; release to create 4 gates.</div>}
      {mode === 'contour' && (
        <div className="hint">
          Hover a density region to preview its contour; scroll to adjust sensitivity ({contourThresholdPct}%); click to create the gate.
        </div>
      )}
      {mode === 'none' && quadrantGroups.size > 0 && (
        <div className="hint hint-subtle">Drag a crosshair intersection to reposition its 4 quadrants.</div>
      )}
      {mode === 'none' && quadrantGroups.size === 0 && (gateNode?.childIds.length ?? 0) > 0 && (
        <div className="hint hint-subtle">Click a gated region to open it in a new panel.</div>
      )}
      <div className="plot-canvas-container" ref={containerRef}>
        <canvas
          ref={canvasRef}
          onMouseDown={handleMouseDown}
          onMouseMove={handleMouseMove}
          onMouseUp={handleMouseUp}
          onDoubleClick={handleDoubleClick}
          onClick={handleClick}
          style={{
            cursor:
              draggingGroupId || shapeDrag || annotDrag
                ? 'grabbing'
                : mode !== 'none'
                  ? 'crosshair'
                  : 'pointer',
          }}
        />
      </div>
      {pendingShape && (
        <GateNameDialog
          defaultName={`Gate ${(gateNode?.childIds.length ?? 0) + 1}`}
          onConfirm={confirmGate}
          onCancel={() => setPendingShape(null)}
        />
      )}
      <div className="gate-panel-resize-handle" title="Drag to resize" onMouseDown={onResizeHandleDown} />
    </div>
  );
}

function formatTick(v: number): string {
  if (Math.abs(v) >= 1000) return `${Math.round(v / 1000)}k`;
  return `${Math.round(v)}`;
}
