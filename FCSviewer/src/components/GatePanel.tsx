import { useEffect, useMemo, useRef, useState } from 'react';
import { useStore } from '../state/store';
import { getColumn, type Sample, type Panel } from '../state/types';
import { ancestorChain, getGateEventIndices, shapeContainsPoint } from '../gating/gateEval';
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
import { densityColor } from '../utils/colormap';
import { GateNameDialog } from './GateNameDialog';
import { PANEL_WIDTH, PANEL_HEIGHT } from '../state/panelLayout';

type Mode = 'none' | 'rectangle' | 'polygon' | 'range' | 'quadrant';

const MARGIN = { top: 16, right: 20, bottom: 42, left: 58 };
const CLOSE_RADIUS_PX = 9;
const QUADRANT_LABEL_OFFSET = 6;

function paramRange(sample: Sample, name: string): number {
  return sample.parameters.find((p) => p.name === name)?.range ?? 1;
}

interface Props {
  sample: Sample;
  panel: Panel;
  isFocused: boolean;
  onDragHandleDown: (e: React.MouseEvent) => void;
  onRegisterCanvas: (panelId: string, el: HTMLCanvasElement | null) => void;
  onRegisterRoot: (panelId: string, el: HTMLDivElement | null) => void;
}

export function GatePanel({ sample, panel, isFocused, onDragHandleDown, onRegisterCanvas, onRegisterRoot }: Props) {
  const {
    updatePanelAxis,
    updatePanelPlotType,
    updatePanelLogScale,
    addGate,
    addQuadrantGates,
    updateQuadrantPosition,
    addChildPanel,
    removePanel,
  } = useStore();
  const rootRef = useRef<HTMLDivElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [size, setSize] = useState({ width: 340, height: 230 });
  const [mode, setMode] = useState<Mode>('none');
  const [rectDraft, setRectDraft] = useState<{ x1: number; y1: number; x2: number; y2: number } | null>(null);
  const [rangeDraft, setRangeDraft] = useState<{ min: number; max: number } | null>(null);
  const [polyPoints, setPolyPoints] = useState<Point[]>([]);
  const [cursorData, setCursorData] = useState<Point | null>(null);
  const [quadrantDraft, setQuadrantDraft] = useState<Point | null>(null);
  const [draggingGroupId, setDraggingGroupId] = useState<string | null>(null);
  const suppressNextClick = useRef(false);
  const [pendingShape, setPendingShape] = useState<GateShape | null>(null);
  const [drawing, setDrawing] = useState(false);

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
    onRegisterCanvas(panel.id, canvasRef.current);
    onRegisterRoot(panel.id, rootRef.current);
    return () => {
      onRegisterCanvas(panel.id, null);
      onRegisterRoot(panel.id, null);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [panel.id]);

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
    setPendingShape(null);
    setDrawing(false);
  }, [panel.xParam, panel.yParam, panel.plotType, xLog, yLog]);

  // Distinct quadrant-gate groups (crosshair placements) among this panel's own child gates.
  const quadrantGroups = useMemo(() => {
    const groups = new Map<string, { x: number; y: number; labels: Partial<Record<QuadrantId, string>> }>();
    for (const childId of gateNode?.childIds ?? []) {
      const shape = sample.gates[childId]?.shape;
      if (shape?.kind !== 'quadrant' || shape.xParam !== panel.xParam || shape.yParam !== panel.yParam) continue;
      const group = groups.get(shape.groupId) ?? { x: shape.x, y: shape.y, labels: {} };
      group.labels[shape.quadrant] = sample.gates[childId].name;
      groups.set(shape.groupId, group);
    }
    return groups;
  }, [sample.gates, gateNode, panel.xParam, panel.yParam]);

  const indices = useMemo(() => getGateEventIndices(sample, panel.gateId), [sample, panel.gateId]);

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
    return { counts, binOf, maxCount, gridN };
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

    ctx.strokeStyle = '#3a3f4b';
    ctx.lineWidth = 1;
    ctx.strokeRect(MARGIN.left, MARGIN.top, plotWidth, plotHeight);

    ctx.fillStyle = '#9aa4b2';
    ctx.font = '10px system-ui, sans-serif';
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
    ctx.font = '11px system-ui, sans-serif';
    ctx.fillText(panel.xParam + (xLog ? ' (log)' : ''), MARGIN.left + plotWidth / 2, size.height - 6);
    ctx.save();
    ctx.translate(12, MARGIN.top + plotHeight / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.fillText(panel.plotType === 'histogram' ? 'Count' : panel.yParam + (yLog ? ' (log)' : ''), 0, 0);
    ctx.restore();

    ctx.save();
    ctx.beginPath();
    ctx.rect(MARGIN.left, MARGIN.top, plotWidth, plotHeight);
    ctx.clip();

    if (panel.plotType === 'histogram' && histogram) {
      const binWidth = plotWidth / histogram.nBins;
      ctx.fillStyle = '#4f8dff';
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
      for (let i = 0; i < indices.length; i++) {
        const idx = indices[i];
        const px = xToPx(xCol[idx]);
        const py = yToPx(yCol[idx]);
        const count = densityGrid.counts[densityGrid.binOf[i]];
        const t = Math.log1p(count) / Math.log1p(densityGrid.maxCount);
        ctx.fillStyle = densityColor(t);
        ctx.fillRect(px - 1, py - 1, 2, 2);
      }
    }

    for (const childId of gateNode?.childIds ?? []) {
      const child = sample.gates[childId];
      const shape = child.shape;
      if (!shape) continue;
      if (shape.kind === 'range' && panel.plotType === 'histogram' && shape.param === panel.xParam) {
        drawRangeOverlay(ctx, xToPx, shape.min, shape.max, MARGIN.top, plotHeight, child.name, false);
      } else if (
        (shape.kind === 'rectangle' || shape.kind === 'polygon') &&
        panel.plotType === 'scatter' &&
        shape.xParam === panel.xParam &&
        shape.yParam === panel.yParam
      ) {
        drawShapeOverlay(ctx, xToPx, yToPx, shape, child.name, false);
      }
    }

    if (panel.plotType === 'scatter') {
      for (const group of quadrantGroups.values()) {
        drawQuadrantCrosshair(ctx, xToPx, yToPx, group.x, group.y, group.labels, false);
      }
    }

    if (mode === 'quadrant' && quadrantDraft) {
      drawQuadrantCrosshair(ctx, xToPx, yToPx, quadrantDraft.x, quadrantDraft.y, null, true);
    }

    if (mode === 'rectangle' && rectDraft) {
      drawShapeOverlay(
        ctx,
        xToPx,
        yToPx,
        { kind: 'rectangle', xParam: panel.xParam, yParam: panel.yParam, ...rectDraft },
        '',
        true
      );
    }
    if (mode === 'range' && rangeDraft) {
      drawRangeOverlay(ctx, xToPx, rangeDraft.min, rangeDraft.max, MARGIN.top, plotHeight, '', true);
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
  });

  function drawShapeOverlay(
    ctx: CanvasRenderingContext2D,
    xPx: (raw: number) => number,
    yPx: (raw: number) => number,
    shape: GateShape,
    label: string,
    isDraft: boolean
  ) {
    ctx.strokeStyle = isDraft ? '#ff9f1c' : '#2ee6a6';
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
      ctx.fillStyle = '#2ee6a6';
      ctx.font = '10px system-ui, sans-serif';
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
    isDraft: boolean
  ) {
    const x1 = xPx(Math.min(min, max));
    const x2 = xPx(Math.max(min, max));
    ctx.fillStyle = isDraft ? 'rgba(255,159,28,0.15)' : 'rgba(46,230,166,0.12)';
    ctx.fillRect(x1, top, x2 - x1, height);
    ctx.strokeStyle = isDraft ? '#ff9f1c' : '#2ee6a6';
    ctx.setLineDash(isDraft ? [5, 3] : []);
    ctx.beginPath();
    ctx.moveTo(x1, top);
    ctx.lineTo(x1, top + height);
    ctx.moveTo(x2, top);
    ctx.lineTo(x2, top + height);
    ctx.stroke();
    ctx.setLineDash([]);
    if (label) {
      ctx.fillStyle = '#2ee6a6';
      ctx.font = '10px system-ui, sans-serif';
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
    isDraft: boolean
  ) {
    const px = xPx(x);
    const py = yPx(y);
    ctx.strokeStyle = isDraft ? '#ff9f1c' : '#2ee6a6';
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
      ctx.font = '10px system-ui, sans-serif';
      ctx.fillStyle = '#2ee6a6';
      ctx.textAlign = 'right';
      if (labels.UL) ctx.fillText(labels.UL, px - QUADRANT_LABEL_OFFSET, MARGIN.top + 10);
      if (labels.LL) ctx.fillText(labels.LL, px - QUADRANT_LABEL_OFFSET, MARGIN.top + plotHeight - 4);
      ctx.textAlign = 'left';
      if (labels.UR) ctx.fillText(labels.UR, px + QUADRANT_LABEL_OFFSET, MARGIN.top + 10);
      if (labels.LR) ctx.fillText(labels.LR, px + QUADRANT_LABEL_OFFSET, MARGIN.top + plotHeight - 4);
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

  function handleMouseDown(e: React.MouseEvent<HTMLCanvasElement>) {
    if (mode === 'none') {
      const groupId = findNearbyQuadrantGroup(e);
      if (groupId) setDraggingGroupId(groupId);
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
    }
  }

  function handleMouseMove(e: React.MouseEvent<HTMLCanvasElement>) {
    if (draggingGroupId) {
      const data = getMouseData(e);
      updateQuadrantPosition(sample.id, draggingGroupId, data.x, data.y);
      return;
    }
    if (mode === 'polygon' && polyPoints.length > 0) {
      setCursorData(getMouseData(e));
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
    if (draggingGroupId) {
      setDraggingGroupId(null);
      suppressNextClick.current = true;
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
      style={{ left: panel.x, top: panel.y, width: PANEL_WIDTH, height: PANEL_HEIGHT }}
    >
      <div className="gate-panel-header" onMouseDown={onDragHandleDown}>
        <span className="gate-panel-title" title={path.map((n) => n.name).join(' › ')}>
          {gateNode?.name ?? 'Population'}
        </span>
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
              }}
            >
              Cancel
            </button>
          )}
        </div>
        <span className="event-count">{indices.length.toLocaleString()}</span>
      </div>
      {mode === 'polygon' && (
        <div className="hint">Click vertices; click near the first, dbl-click, or Enter to close.</div>
      )}
      {mode === 'quadrant' && <div className="hint">Click-drag to place the crosshair; release to create 4 gates.</div>}
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
          style={{ cursor: draggingGroupId ? 'grabbing' : mode !== 'none' ? 'crosshair' : 'pointer' }}
        />
      </div>
      {pendingShape && (
        <GateNameDialog
          defaultName={`Gate ${(gateNode?.childIds.length ?? 0) + 1}`}
          onConfirm={confirmGate}
          onCancel={() => setPendingShape(null)}
        />
      )}
    </div>
  );
}

function formatTick(v: number): string {
  if (Math.abs(v) >= 1000) return `${Math.round(v / 1000)}k`;
  return `${Math.round(v)}`;
}
