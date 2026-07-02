import { useEffect, useMemo, useRef, useState } from 'react';
import { useStore } from '../state/store';
import { getColumn, type Sample } from '../state/types';
import { ancestorChain, getGateEventIndices, shapeContainsPoint } from '../gating/gateEval';
import type { GateShape, Point } from '../gating/gateTypes';
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

type Mode = 'none' | 'rectangle' | 'polygon' | 'range';

const MARGIN = { top: 16, right: 24, bottom: 46, left: 64 };
const CLOSE_RADIUS_PX = 9;

function paramRange(sample: Sample, name: string): number {
  return sample.parameters.find((p) => p.name === name)?.range ?? 1;
}

export function PlotCanvas({ sample }: { sample: Sample }) {
  const { setAxis, setPlotType, setLogScale, addGate, selectGate } = useStore();
  const containerRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [size, setSize] = useState({ width: 640, height: 560 });
  const [mode, setMode] = useState<Mode>('none');
  const [rectDraft, setRectDraft] = useState<{ x1: number; y1: number; x2: number; y2: number } | null>(null);
  const [rangeDraft, setRangeDraft] = useState<{ min: number; max: number } | null>(null);
  const [polyPoints, setPolyPoints] = useState<Point[]>([]);
  const [cursorData, setCursorData] = useState<Point | null>(null);
  const [pendingShape, setPendingShape] = useState<GateShape | null>(null);
  const [drawing, setDrawing] = useState(false);

  const xLog = sample.xLogScale;
  const yLog = sample.plotType === 'scatter' && sample.yLogScale;

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      const box = entries[0].contentRect;
      setSize({ width: Math.max(320, box.width), height: Math.max(320, box.height) });
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
        setPendingShape(null);
        setDrawing(false);
      }
      if (e.key === 'Enter' && mode === 'polygon' && polyPoints.length >= 3) {
        setPendingShape({ kind: 'polygon', xParam: sample.xParam, yParam: sample.yParam, points: polyPoints });
      }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [mode, polyPoints, sample.xParam, sample.yParam]);

  // Reset any in-progress draw when the population, axes, plot type, or scale changes.
  useEffect(() => {
    setMode('none');
    setRectDraft(null);
    setRangeDraft(null);
    setPolyPoints([]);
    setPendingShape(null);
    setDrawing(false);
  }, [sample.activeGateId, sample.xParam, sample.yParam, sample.plotType, sample.id, xLog, yLog]);

  const indices = useMemo(() => getGateEventIndices(sample, sample.activeGateId), [sample]);
  const breadcrumb = useMemo(() => ancestorChain(sample.gates, sample.activeGateId), [sample]);

  const plotWidth = size.width - MARGIN.left - MARGIN.right;
  const plotHeight = size.height - MARGIN.top - MARGIN.bottom;

  const xDomainMax = paramRange(sample, sample.xParam);
  const yDomainMax = sample.plotType === 'scatter' ? paramRange(sample, sample.yParam) : 0;

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

  // Histogram Y domain depends on bin counts, computed below; scatter Y domain is the param range.
  const histogram = useMemo(() => {
    if (sample.plotType !== 'histogram') return null;
    const nBins = 200;
    const col = getColumn(sample, sample.xParam);
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
  }, [sample, indices, xDomainMax, xLog]);

  const scaleY: LinearScale = useMemo(() => {
    if (sample.plotType === 'histogram') {
      return makeScale(0, histogram?.max ?? 1, MARGIN.top + plotHeight, MARGIN.top);
    }
    return makeScale(
      dataToPlotValue(yLog ? 1 : 0, yLog),
      dataToPlotValue(yDomainMax, yLog),
      MARGIN.top + plotHeight,
      MARGIN.top
    );
  }, [sample.plotType, histogram, yDomainMax, plotHeight, yLog]);

  // Pixel <-> raw-data-value helpers. Gate shapes always store raw values;
  // only the pixel mapping is aware of the log/linear toggle.
  const xToPx = (raw: number) => toRange(scaleX, dataToPlotValue(raw, xLog));
  const pxToX = (px: number) => plotValueToData(toDomain(scaleX, px), xLog);
  const yToPx = (raw: number) => toRange(scaleY, dataToPlotValue(raw, yLog));
  const pxToY = (px: number) => plotValueToData(toDomain(scaleY, px), yLog);

  // Density lookup for scatter pseudocolor: bin the displayed population on a coarse grid
  // in plot (post-transform) space so bins are visually even under a log scale.
  const densityGrid = useMemo(() => {
    if (sample.plotType !== 'scatter') return null;
    const gridN = 96;
    const xCol = getColumn(sample, sample.xParam);
    const yCol = getColumn(sample, sample.yParam);
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
  }, [sample, indices, xDomainMax, yDomainMax, xLog, yLog]);

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
    ctx.clearRect(0, 0, size.width, size.height);

    // Plot border + axes
    ctx.strokeStyle = '#3a3f4b';
    ctx.lineWidth = 1;
    ctx.strokeRect(MARGIN.left, MARGIN.top, plotWidth, plotHeight);

    ctx.fillStyle = '#9aa4b2';
    ctx.font = '11px system-ui, sans-serif';
    ctx.textAlign = 'center';
    const xTicks = xLog ? logTicks(xDomainMax) : niceTicks(0, xDomainMax);
    for (const t of xTicks) {
      const px = xToPx(t);
      ctx.beginPath();
      ctx.moveTo(px, MARGIN.top + plotHeight);
      ctx.lineTo(px, MARGIN.top + plotHeight + 4);
      ctx.stroke();
      ctx.fillText(formatTick(t), px, MARGIN.top + plotHeight + 16);
    }
    ctx.textAlign = 'right';
    const yTicks =
      sample.plotType === 'scatter' && yLog ? logTicks(yDomainMax) : niceTicks(0, sample.plotType === 'histogram' ? (histogram?.max ?? 1) : yDomainMax);
    for (const t of yTicks) {
      const py = sample.plotType === 'histogram' ? toRange(scaleY, t) : yToPx(t);
      ctx.beginPath();
      ctx.moveTo(MARGIN.left - 4, py);
      ctx.lineTo(MARGIN.left, py);
      ctx.stroke();
      ctx.fillText(formatTick(t), MARGIN.left - 8, py + 3);
    }
    ctx.textAlign = 'center';
    ctx.fillStyle = '#c7cdd6';
    ctx.font = '12px system-ui, sans-serif';
    ctx.fillText(sample.xParam + (xLog ? ' (log)' : ''), MARGIN.left + plotWidth / 2, size.height - 8);
    ctx.save();
    ctx.translate(14, MARGIN.top + plotHeight / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.fillText(sample.plotType === 'histogram' ? 'Count' : sample.yParam + (yLog ? ' (log)' : ''), 0, 0);
    ctx.restore();

    // Clip to plot area for data drawing
    ctx.save();
    ctx.beginPath();
    ctx.rect(MARGIN.left, MARGIN.top, plotWidth, plotHeight);
    ctx.clip();

    if (sample.plotType === 'histogram' && histogram) {
      const binWidth = plotWidth / histogram.nBins;
      ctx.fillStyle = '#4f8dff';
      for (let b = 0; b < histogram.nBins; b++) {
        const c = histogram.counts[b];
        if (c === 0) continue;
        const x = MARGIN.left + b * binWidth;
        const yTop = toRange(scaleY, c);
        ctx.fillRect(x, yTop, Math.max(1, binWidth), MARGIN.top + plotHeight - yTop);
      }
    } else if (sample.plotType === 'scatter' && densityGrid) {
      const xCol = getColumn(sample, sample.xParam);
      const yCol = getColumn(sample, sample.yParam);
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

    // Overlay existing child gates of the active population
    const activeNode = sample.gates[sample.activeGateId];
    for (const childId of activeNode?.childIds ?? []) {
      const child = sample.gates[childId];
      const shape = child.shape;
      if (!shape) continue;
      if (shape.kind === 'range' && sample.plotType === 'histogram' && shape.param === sample.xParam) {
        drawRangeOverlay(ctx, xToPx, shape.min, shape.max, MARGIN.top, plotHeight, child.name, false);
      } else if (
        shape.kind !== 'range' &&
        sample.plotType === 'scatter' &&
        shape.xParam === sample.xParam &&
        shape.yParam === sample.yParam
      ) {
        drawShapeOverlay(ctx, xToPx, yToPx, shape, child.name, false);
      }
    }

    // Draft (in-progress) shape
    if (mode === 'rectangle' && rectDraft) {
      drawShapeOverlay(
        ctx,
        xToPx,
        yToPx,
        { kind: 'rectangle', xParam: sample.xParam, yParam: sample.yParam, ...rectDraft },
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
      ctx.font = '11px system-ui, sans-serif';
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
      ctx.font = '11px system-ui, sans-serif';
      ctx.textAlign = 'left';
      ctx.fillText(label, x1 + 3, top + 12);
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

  function handleMouseDown(e: React.MouseEvent<HTMLCanvasElement>) {
    if (mode === 'none') return;
    const data = getMouseData(e);
    if (mode === 'rectangle') {
      setRectDraft({ x1: data.x, y1: data.y, x2: data.x, y2: data.y });
      setDrawing(true);
    } else if (mode === 'range') {
      setRangeDraft({ min: data.x, max: data.x });
      setDrawing(true);
    } else if (mode === 'polygon') {
      if (polyPoints.length >= 3) {
        const first = polyPoints[0];
        const firstPx = { x: xToPx(first.x), y: yToPx(first.y) };
        const px = getMousePx(e);
        const dist = Math.hypot(px.x - firstPx.x, px.y - firstPx.y);
        if (dist <= CLOSE_RADIUS_PX) {
          setPendingShape({ kind: 'polygon', xParam: sample.xParam, yParam: sample.yParam, points: polyPoints });
          return;
        }
      }
      setPolyPoints((pts) => [...pts, data]);
    }
  }

  function handleMouseMove(e: React.MouseEvent<HTMLCanvasElement>) {
    if (mode === 'polygon' && polyPoints.length > 0) {
      setCursorData(getMouseData(e));
    }
    if (!drawing) return;
    const data = getMouseData(e);
    if (mode === 'rectangle' && rectDraft) {
      setRectDraft({ ...rectDraft, x2: data.x, y2: data.y });
    } else if (mode === 'range' && rangeDraft) {
      setRangeDraft({ ...rangeDraft, max: data.x });
    }
  }

  function handleMouseUp() {
    if (!drawing) return;
    setDrawing(false);
    if (mode === 'rectangle' && rectDraft) {
      if (Math.abs(rectDraft.x1 - rectDraft.x2) > 1e-6 && Math.abs(rectDraft.y1 - rectDraft.y2) > 1e-6) {
        setPendingShape({ kind: 'rectangle', xParam: sample.xParam, yParam: sample.yParam, ...rectDraft });
      } else {
        setRectDraft(null);
      }
    } else if (mode === 'range' && rangeDraft) {
      if (Math.abs(rangeDraft.min - rangeDraft.max) > 1e-6) {
        setPendingShape({ kind: 'range', param: sample.xParam, min: rangeDraft.min, max: rangeDraft.max });
      } else {
        setRangeDraft(null);
      }
    }
  }

  function handleDoubleClick() {
    if (mode === 'polygon' && polyPoints.length >= 3) {
      setPendingShape({ kind: 'polygon', xParam: sample.xParam, yParam: sample.yParam, points: polyPoints });
    }
  }

  // Clicking directly on an existing child gate's shape (outside of drawing mode) drills into it.
  function handleClick(e: React.MouseEvent<HTMLCanvasElement>) {
    if (mode !== 'none') return;
    const data = getMouseData(e);
    const activeNode = sample.gates[sample.activeGateId];
    for (const childId of activeNode?.childIds ?? []) {
      const child = sample.gates[childId];
      const shape = child.shape;
      if (!shape) continue;
      if (sample.plotType === 'histogram' && shape.kind === 'range' && shape.param === sample.xParam) {
        if (shapeContainsPoint(shape, data.x, 0)) {
          selectGate(sample.id, childId);
          return;
        }
      } else if (
        sample.plotType === 'scatter' &&
        shape.kind !== 'range' &&
        shape.xParam === sample.xParam &&
        shape.yParam === sample.yParam
      ) {
        if (shapeContainsPoint(shape, data.x, data.y)) {
          selectGate(sample.id, childId);
          return;
        }
      }
    }
  }

  function confirmGate(name: string) {
    if (!pendingShape) return;
    addGate(sample.id, sample.activeGateId, name, pendingShape);
    setPendingShape(null);
    setRectDraft(null);
    setRangeDraft(null);
    setPolyPoints([]);
    setMode('none');
  }

  const params = sample.parameters;

  return (
    <div className="plot-panel">
      <div className="plot-toolbar">
        <label>
          X:
          <select value={sample.xParam} onChange={(e) => setAxis(sample.id, 'xParam', e.target.value)}>
            {params.map((p) => (
              <option key={p.name} value={p.name}>
                {p.label !== p.name ? `${p.name} (${p.label})` : p.name}
              </option>
            ))}
          </select>
        </label>
        <button
          className={`btn ${xLog ? 'btn-active' : ''}`}
          title="Toggle logarithmic X axis"
          onClick={() => setLogScale(sample.id, 'xLogScale', !sample.xLogScale)}
        >
          log X
        </button>
        {sample.plotType === 'scatter' && (
          <>
            <label>
              Y:
              <select value={sample.yParam} onChange={(e) => setAxis(sample.id, 'yParam', e.target.value)}>
                {params.map((p) => (
                  <option key={p.name} value={p.name}>
                    {p.label !== p.name ? `${p.name} (${p.label})` : p.name}
                  </option>
                ))}
              </select>
            </label>
            <button
              className={`btn ${yLog ? 'btn-active' : ''}`}
              title="Toggle logarithmic Y axis"
              onClick={() => setLogScale(sample.id, 'yLogScale', !sample.yLogScale)}
            >
              log Y
            </button>
          </>
        )}
        <div className="btn-group">
          <button
            className={`btn ${sample.plotType === 'scatter' ? 'btn-active' : ''}`}
            onClick={() => setPlotType(sample.id, 'scatter')}
          >
            Dot plot
          </button>
          <button
            className={`btn ${sample.plotType === 'histogram' ? 'btn-active' : ''}`}
            onClick={() => setPlotType(sample.id, 'histogram')}
          >
            Histogram
          </button>
        </div>
        <div className="btn-group">
          {sample.plotType === 'scatter' ? (
            <>
              <button
                className={`btn ${mode === 'rectangle' ? 'btn-active' : ''}`}
                onClick={() => setMode(mode === 'rectangle' ? 'none' : 'rectangle')}
              >
                ▭ Rectangle gate
              </button>
              <button
                className={`btn ${mode === 'polygon' ? 'btn-active' : ''}`}
                onClick={() => setMode(mode === 'polygon' ? 'none' : 'polygon')}
              >
                ⬠ Polygon gate
              </button>
            </>
          ) : (
            <button
              className={`btn ${mode === 'range' ? 'btn-active' : ''}`}
              onClick={() => setMode(mode === 'range' ? 'none' : 'range')}
            >
              ↔ Range gate
            </button>
          )}
          {mode !== 'none' && (
            <button
              className="btn"
              onClick={() => {
                setMode('none');
                setRectDraft(null);
                setRangeDraft(null);
                setPolyPoints([]);
              }}
            >
              Cancel
            </button>
          )}
        </div>
        <span className="event-count">
          {indices.length.toLocaleString()} / {sample.eventCount.toLocaleString()} events
        </span>
      </div>
      <div className="breadcrumb">
        {breadcrumb.map((node, i) => (
          <span key={node.id}>
            {i > 0 && <span className="breadcrumb-sep">›</span>}
            <span
              className={`breadcrumb-item ${node.id === sample.activeGateId ? 'breadcrumb-current' : ''}`}
              onClick={() => node.id !== sample.activeGateId && selectGate(sample.id, node.id)}
            >
              {node.name}
            </span>
          </span>
        ))}
      </div>
      {mode === 'polygon' && (
        <div className="hint">Click to add vertices. Click near the first point, double-click, or press Enter to close.</div>
      )}
      {mode === 'none' && breadcrumb[breadcrumb.length - 1]?.childIds.length > 0 && (
        <div className="hint hint-subtle">Click a gated region to drill into it.</div>
      )}
      <div className="plot-canvas-container" ref={containerRef}>
        <canvas
          ref={canvasRef}
          onMouseDown={handleMouseDown}
          onMouseMove={handleMouseMove}
          onMouseUp={handleMouseUp}
          onDoubleClick={handleDoubleClick}
          onClick={handleClick}
          style={{ cursor: mode !== 'none' ? 'crosshair' : 'pointer' }}
        />
      </div>
      {pendingShape && (
        <GateNameDialog
          defaultName={`Gate ${(sample.gates[sample.activeGateId]?.childIds.length ?? 0) + 1}`}
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
