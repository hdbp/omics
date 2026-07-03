import { useEffect, useMemo, useRef, useState } from 'react';
import { useStore } from '../state/store';
import { getColumn, type Sample, type LayoutItem } from '../state/types';
import { ancestorChain, getGateEventIndices } from '../gating/gateEval';
import type { GateShape, QuadrantId } from '../gating/gateTypes';
import { makeScale, toRange, niceTicks, logTicks, dataToPlotValue, type LinearScale } from '../utils/scale';
import { densityColor } from '../utils/colormap';

const MARGIN = { top: 16, right: 20, bottom: 42, left: 58 };
const QUADRANT_LABEL_OFFSET = 6;
const DEFAULT_GATE_COLOR = '#2ee6a6';
const DEFAULT_HISTOGRAM_COLOR = '#4f8dff';

function paramRange(sample: Sample, name: string): number {
  return sample.parameters.find((p) => p.name === name)?.range ?? 1;
}

interface Props {
  item: LayoutItem;
  sample: Sample | undefined;
  isFocused: boolean;
  onDragHandleDown: (e: React.MouseEvent) => void;
  onResizeHandleDown: (e: React.MouseEvent) => void;
  onRegisterCanvas: (itemId: string, el: HTMLCanvasElement | null) => void;
  onRegisterRoot: (itemId: string, el: HTMLDivElement | null) => void;
}

/**
 * A read-only-for-gating plot in the Layout collage: shows a population's
 * plot (with its existing child gates drawn for context) for assembling a
 * figure. Axes/plot type/log scale/label are editable; no new gates can be
 * drawn here — that happens in the sample's own workspace.
 */
export function LayoutPanel({ item, sample, isFocused, onDragHandleDown, onResizeHandleDown, onRegisterCanvas, onRegisterRoot }: Props) {
  const { updateLayoutItemAxis, updateLayoutItemPlotType, updateLayoutItemLogScale, relabelLayoutItem, removeLayoutItem } =
    useStore();
  const rootRef = useRef<HTMLDivElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [editingLabel, setEditingLabel] = useState(false);
  const [labelValue, setLabelValue] = useState('');
  const [size, setSize] = useState({ width: 340, height: 230 });

  const xLog = item.xLogScale;
  const yLog = item.plotType === 'scatter' && item.yLogScale;
  const gateNode = sample?.gates[item.gateId];
  const path = useMemo(() => (sample ? ancestorChain(sample.gates, item.gateId) : []), [sample, item.gateId]);

  useEffect(() => {
    if (isFocused) rootRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'nearest' });
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
    onRegisterCanvas(item.id, canvasRef.current);
    onRegisterRoot(item.id, rootRef.current);
    return () => {
      onRegisterCanvas(item.id, null);
      onRegisterRoot(item.id, null);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item.id]);

  const indices = useMemo(() => (sample ? getGateEventIndices(sample, item.gateId) : new Uint32Array(0)), [sample, item.gateId]);

  const plotWidth = size.width - MARGIN.left - MARGIN.right;
  const plotHeight = size.height - MARGIN.top - MARGIN.bottom;

  const xDomainMax = sample ? paramRange(sample, item.xParam) : 1;
  const yDomainMax = sample && item.plotType === 'scatter' ? paramRange(sample, item.yParam) : 0;

  const scaleX: LinearScale = useMemo(
    () => makeScale(dataToPlotValue(xLog ? 1 : 0, xLog), dataToPlotValue(xDomainMax, xLog), MARGIN.left, MARGIN.left + plotWidth),
    [xDomainMax, plotWidth, xLog]
  );

  const histogram = useMemo(() => {
    if (!sample || item.plotType !== 'histogram') return null;
    const nBins = 150;
    const col = getColumn(sample, item.xParam);
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
  }, [sample, item.plotType, item.xParam, indices, xDomainMax, xLog]);

  const scaleY: LinearScale = useMemo(() => {
    if (item.plotType === 'histogram') return makeScale(0, histogram?.max ?? 1, MARGIN.top + plotHeight, MARGIN.top);
    return makeScale(dataToPlotValue(yLog ? 1 : 0, yLog), dataToPlotValue(yDomainMax, yLog), MARGIN.top + plotHeight, MARGIN.top);
  }, [item.plotType, histogram, yDomainMax, plotHeight, yLog]);

  const xToPx = (raw: number) => toRange(scaleX, dataToPlotValue(raw, xLog));
  const yToPx = (raw: number) => toRange(scaleY, dataToPlotValue(raw, yLog));

  const densityGrid = useMemo(() => {
    if (!sample || item.plotType !== 'scatter') return null;
    const gridN = 80;
    const xCol = getColumn(sample, item.xParam);
    const yCol = getColumn(sample, item.yParam);
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
  }, [sample, item.plotType, item.xParam, item.yParam, indices, xDomainMax, yDomainMax, xLog, yLog]);

  const quadrantGroups = useMemo(() => {
    const groups = new Map<
      string,
      { x: number; y: number; labels: Partial<Record<QuadrantId, string>>; colors: Partial<Record<QuadrantId, string>> }
    >();
    if (!sample) return groups;
    for (const childId of gateNode?.childIds ?? []) {
      const child = sample.gates[childId];
      const shape = child?.shape;
      if (shape?.kind !== 'quadrant' || shape.xParam !== item.xParam || shape.yParam !== item.yParam) continue;
      const group = groups.get(shape.groupId) ?? { x: shape.x, y: shape.y, labels: {}, colors: {} };
      group.labels[shape.quadrant] = child.name;
      if (child.color) group.colors[shape.quadrant] = child.color;
      groups.set(shape.groupId, group);
    }
    return groups;
  }, [sample, gateNode, item.xParam, item.yParam]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !sample) return;
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
      item.plotType === 'scatter' && yLog ? logTicks(yDomainMax) : niceTicks(0, item.plotType === 'histogram' ? (histogram?.max ?? 1) : yDomainMax);
    for (const t of yTicks) {
      const py = item.plotType === 'histogram' ? toRange(scaleY, t) : yToPx(t);
      ctx.beginPath();
      ctx.moveTo(MARGIN.left - 4, py);
      ctx.lineTo(MARGIN.left, py);
      ctx.stroke();
      ctx.fillText(formatTick(t), MARGIN.left - 7, py + 3);
    }
    ctx.textAlign = 'center';
    ctx.fillStyle = '#c7cdd6';
    ctx.font = '11px system-ui, sans-serif';
    ctx.fillText(item.xParam + (xLog ? ' (log)' : ''), MARGIN.left + plotWidth / 2, size.height - 6);
    ctx.save();
    ctx.translate(12, MARGIN.top + plotHeight / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.fillText(item.plotType === 'histogram' ? 'Count' : item.yParam + (yLog ? ' (log)' : ''), 0, 0);
    ctx.restore();

    ctx.save();
    ctx.beginPath();
    ctx.rect(MARGIN.left, MARGIN.top, plotWidth, plotHeight);
    ctx.clip();

    const ownColor = gateNode?.color;
    if (item.plotType === 'histogram' && histogram) {
      const binWidth = plotWidth / histogram.nBins;
      ctx.fillStyle = ownColor ?? DEFAULT_HISTOGRAM_COLOR;
      for (let b = 0; b < histogram.nBins; b++) {
        const c = histogram.counts[b];
        if (c === 0) continue;
        const x = MARGIN.left + b * binWidth;
        const yTop = toRange(scaleY, c);
        ctx.fillRect(x, yTop, Math.max(1, binWidth), MARGIN.top + plotHeight - yTop);
      }
    } else if (item.plotType === 'scatter' && densityGrid) {
      const xCol = getColumn(sample, item.xParam);
      const yCol = getColumn(sample, item.yParam);
      if (ownColor) ctx.fillStyle = ownColor;
      for (let i = 0; i < indices.length; i++) {
        const idx = indices[i];
        const px = xToPx(xCol[idx]);
        const py = yToPx(yCol[idx]);
        if (!ownColor) {
          const count = densityGrid.counts[densityGrid.binOf[i]];
          const t = Math.log1p(count) / Math.log1p(densityGrid.maxCount);
          ctx.fillStyle = densityColor(t);
        }
        ctx.fillRect(px - 1, py - 1, 2, 2);
      }
    }

    for (const childId of gateNode?.childIds ?? []) {
      const child = sample.gates[childId];
      const shape = child.shape;
      if (!shape) continue;
      if (shape.kind === 'range' && item.plotType === 'histogram' && shape.param === item.xParam) {
        drawRangeOverlay(ctx, xToPx, shape.min, shape.max, MARGIN.top, plotHeight, child.name, child.color ?? DEFAULT_GATE_COLOR);
      } else if (
        (shape.kind === 'rectangle' || shape.kind === 'polygon') &&
        item.plotType === 'scatter' &&
        shape.xParam === item.xParam &&
        shape.yParam === item.yParam
      ) {
        drawShapeOverlay(ctx, xToPx, yToPx, shape, child.name, child.color ?? DEFAULT_GATE_COLOR);
      }
    }
    if (item.plotType === 'scatter') {
      for (const group of quadrantGroups.values()) {
        drawQuadrantCrosshair(ctx, xToPx, yToPx, group.x, group.y, group.labels, group.colors);
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
    color: string
  ) {
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.5;
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
    if (label) {
      ctx.fillStyle = color;
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
    color: string
  ) {
    const x1 = xPx(Math.min(min, max));
    const x2 = xPx(Math.max(min, max));
    ctx.strokeStyle = color;
    ctx.beginPath();
    ctx.moveTo(x1, top);
    ctx.lineTo(x1, top + height);
    ctx.moveTo(x2, top);
    ctx.lineTo(x2, top + height);
    ctx.stroke();
    if (label) {
      ctx.fillStyle = color;
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
    labels: Partial<Record<QuadrantId, string>>,
    labelColors: Partial<Record<QuadrantId, string>>
  ) {
    const px = xPx(x);
    const py = yPx(y);
    ctx.strokeStyle = DEFAULT_GATE_COLOR;
    ctx.lineWidth = 1.25;
    ctx.beginPath();
    ctx.moveTo(px, MARGIN.top);
    ctx.lineTo(px, MARGIN.top + plotHeight);
    ctx.moveTo(MARGIN.left, py);
    ctx.lineTo(MARGIN.left + plotWidth, py);
    ctx.stroke();
    ctx.font = '10px system-ui, sans-serif';
    ctx.textAlign = 'right';
    if (labels.UL) {
      ctx.fillStyle = labelColors.UL ?? DEFAULT_GATE_COLOR;
      ctx.fillText(labels.UL, px - QUADRANT_LABEL_OFFSET, MARGIN.top + 10);
    }
    if (labels.LL) {
      ctx.fillStyle = labelColors.LL ?? DEFAULT_GATE_COLOR;
      ctx.fillText(labels.LL, px - QUADRANT_LABEL_OFFSET, MARGIN.top + plotHeight - 4);
    }
    ctx.textAlign = 'left';
    if (labels.UR) {
      ctx.fillStyle = labelColors.UR ?? DEFAULT_GATE_COLOR;
      ctx.fillText(labels.UR, px + QUADRANT_LABEL_OFFSET, MARGIN.top + 10);
    }
    if (labels.LR) {
      ctx.fillStyle = labelColors.LR ?? DEFAULT_GATE_COLOR;
      ctx.fillText(labels.LR, px + QUADRANT_LABEL_OFFSET, MARGIN.top + plotHeight - 4);
    }
  }

  if (!sample) {
    return (
      <div ref={rootRef} className="gate-panel" style={{ left: item.x, top: item.y, width: item.width, height: item.height }}>
        <div className="gate-panel-header" onMouseDown={onDragHandleDown}>
          <span className="gate-panel-title">{item.label}</span>
          <button className="gate-panel-close" onMouseDown={(e) => e.stopPropagation()} onClick={() => removeLayoutItem(item.id)}>
            ×
          </button>
        </div>
        <div className="layout-panel-missing">Source sample was removed.</div>
        <div className="gate-panel-resize-handle" onMouseDown={onResizeHandleDown} />
      </div>
    );
  }

  const params = sample.parameters;

  return (
    <div
      ref={rootRef}
      className={`gate-panel ${isFocused ? 'gate-panel-focused' : ''}`}
      style={{ left: item.x, top: item.y, width: item.width, height: item.height }}
    >
      <div className="gate-panel-header" onMouseDown={onDragHandleDown}>
        {editingLabel ? (
          <input
            autoFocus
            className="gate-panel-title-input"
            value={labelValue}
            onMouseDown={(e) => e.stopPropagation()}
            onChange={(e) => setLabelValue(e.target.value)}
            onBlur={() => {
              if (labelValue.trim()) relabelLayoutItem(item.id, labelValue.trim());
              setEditingLabel(false);
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                if (labelValue.trim()) relabelLayoutItem(item.id, labelValue.trim());
                setEditingLabel(false);
              }
              if (e.key === 'Escape') setEditingLabel(false);
            }}
          />
        ) : (
          <span
            className="gate-panel-title"
            title={`${sample.fileName} · ${path.map((n) => n.name).join(' › ')} (double-click to relabel)`}
            onDoubleClick={(e) => {
              e.stopPropagation();
              setLabelValue(item.label);
              setEditingLabel(true);
            }}
          >
            {item.label}
          </span>
        )}
        <button className="gate-panel-close" title="Remove from layout" onMouseDown={(e) => e.stopPropagation()} onClick={() => removeLayoutItem(item.id)}>
          ×
        </button>
      </div>
      <div className="gate-panel-path">
        {sample.fileName} · {path.map((n) => n.name).join(' › ')}
      </div>
      <div className="plot-toolbar">
        <label>
          X:
          <select value={item.xParam} onChange={(e) => updateLayoutItemAxis(item.id, 'xParam', e.target.value)}>
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
          onClick={() => updateLayoutItemLogScale(item.id, 'xLogScale', !item.xLogScale)}
        >
          log X
        </button>
        {item.plotType === 'scatter' && (
          <>
            <label>
              Y:
              <select value={item.yParam} onChange={(e) => updateLayoutItemAxis(item.id, 'yParam', e.target.value)}>
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
              onClick={() => updateLayoutItemLogScale(item.id, 'yLogScale', !item.yLogScale)}
            >
              log Y
            </button>
          </>
        )}
      </div>
      <div className="plot-toolbar">
        <div className="btn-group">
          <button
            className={`btn btn-small ${item.plotType === 'scatter' ? 'btn-active' : ''}`}
            onClick={() => updateLayoutItemPlotType(item.id, 'scatter')}
          >
            Dot plot
          </button>
          <button
            className={`btn btn-small ${item.plotType === 'histogram' ? 'btn-active' : ''}`}
            onClick={() => updateLayoutItemPlotType(item.id, 'histogram')}
          >
            Histogram
          </button>
        </div>
        <span className="event-count">{indices.length.toLocaleString()}</span>
      </div>
      <div className="plot-canvas-container" ref={containerRef}>
        <canvas ref={canvasRef} style={{ cursor: 'default' }} />
      </div>
      <div className="gate-panel-resize-handle" title="Drag to resize" onMouseDown={onResizeHandleDown} />
    </div>
  );
}

function formatTick(v: number): string {
  if (Math.abs(v) >= 1000) return `${Math.round(v / 1000)}k`;
  return `${Math.round(v)}`;
}
