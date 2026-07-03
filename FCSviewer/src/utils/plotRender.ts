import { getColumn, type Sample } from '../state/types';
import { getGateEventIndices } from '../gating/gateEval';
import { gatePercentages } from '../gating/gateStats';
import type { GateNode, GateShape, QuadrantId } from '../gating/gateTypes';
import { makeScale, toRange, niceTicks, logTicks, dataToPlotValue, type LinearScale } from './scale';
import { densityColor, hexToRgba } from './colormap';
import type { PlotTheme } from './theme';

const MARGIN = { top: 16, right: 20, bottom: 42, left: 58 };
const QUADRANT_LABEL_OFFSET = 6;
const ANNOTATION_PADDING = 6;
const ANNOTATION_LINE_HEIGHT = 13;
const DEFAULT_STATS_ANNOTATION = { xFrac: 0.03, yFrac: 0.06 };

function paramRange(sample: Sample, name: string): number {
  return sample.parameters.find((p) => p.name === name)?.range ?? 1;
}

function formatTick(v: number): string {
  if (Math.abs(v) >= 1000) return `${Math.round(v / 1000)}k`;
  return `${Math.round(v)}`;
}

/** Everything a Panel or a LayoutItem carries that's needed to re-render its plot; both types satisfy this shape. */
export interface PlotRenderSpec {
  sample: Sample;
  gateId: string;
  xParam: string;
  yParam: string;
  plotType: 'scatter' | 'histogram';
  xLogScale: boolean;
  yLogScale: boolean;
  xAxisLabel?: string;
  yAxisLabel?: string;
  statsAnnotation?: { xFrac: number; yFrac: number };
}

/**
 * Re-renders a panel's plot (ticks, density/histogram, gate overlays, quadrant crosshairs, stats badge) directly
 * onto an export canvas at (originX, originY), sized (width, height). Independent of any live DOM canvas, so an
 * export can freely pick its own color theme rather than snapshotting the app's always-dark interactive canvas.
 */
export function drawPlotPanel(
  ctx: CanvasRenderingContext2D,
  originX: number,
  originY: number,
  width: number,
  height: number,
  spec: PlotRenderSpec,
  theme: PlotTheme
): void {
  const { sample, gateId, xParam, yParam, plotType, xLogScale, yLogScale } = spec;
  const gateNode = sample.gates[gateId];
  const indices = getGateEventIndices(sample, gateId);
  const xLog = xLogScale;
  const yLog = plotType === 'scatter' && yLogScale;

  const plotWidth = width - MARGIN.left - MARGIN.right;
  const plotHeight = height - MARGIN.top - MARGIN.bottom;
  ctx.fillStyle = theme.plotBg;
  ctx.fillRect(originX, originY, width, height);
  if (plotWidth <= 0 || plotHeight <= 0) return;

  const left = originX + MARGIN.left;
  const top = originY + MARGIN.top;

  const xDomainMax = paramRange(sample, xParam);
  const yDomainMax = plotType === 'scatter' ? paramRange(sample, yParam) : 0;

  const scaleX: LinearScale = makeScale(dataToPlotValue(xLog ? 1 : 0, xLog), dataToPlotValue(xDomainMax, xLog), left, left + plotWidth);

  let histogram: { counts: Uint32Array; nBins: number; max: number } | null = null;
  if (plotType === 'histogram') {
    const nBins = 150;
    const col = getColumn(sample, xParam);
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
    histogram = { counts, nBins, max };
  }

  const scaleY: LinearScale =
    plotType === 'histogram'
      ? makeScale(0, histogram?.max ?? 1, top + plotHeight, top)
      : makeScale(dataToPlotValue(yLog ? 1 : 0, yLog), dataToPlotValue(yDomainMax, yLog), top + plotHeight, top);

  const xToPx = (raw: number) => toRange(scaleX, dataToPlotValue(raw, xLog));
  const yToPx = (raw: number) => toRange(scaleY, dataToPlotValue(raw, yLog));

  let densityGrid: { counts: Uint32Array; binOf: Int32Array; maxCount: number } | null = null;
  if (plotType === 'scatter') {
    const gridN = 80;
    const xCol = getColumn(sample, xParam);
    const yCol = getColumn(sample, yParam);
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
    densityGrid = { counts, binOf, maxCount };
  }

  ctx.strokeStyle = theme.plotBorder;
  ctx.lineWidth = 1;
  ctx.strokeRect(left, top, plotWidth, plotHeight);

  ctx.fillStyle = theme.tickText;
  ctx.font = '10px system-ui, sans-serif';
  ctx.textAlign = 'center';
  const xTicks = xLog ? logTicks(xDomainMax) : niceTicks(0, xDomainMax);
  for (const t of xTicks) {
    const px = xToPx(t);
    ctx.beginPath();
    ctx.moveTo(px, top + plotHeight);
    ctx.lineTo(px, top + plotHeight + 4);
    ctx.stroke();
    ctx.fillText(formatTick(t), px, top + plotHeight + 14);
  }
  ctx.textAlign = 'right';
  const yTicks = plotType === 'scatter' && yLog ? logTicks(yDomainMax) : niceTicks(0, plotType === 'histogram' ? (histogram?.max ?? 1) : yDomainMax);
  for (const t of yTicks) {
    const py = plotType === 'histogram' ? toRange(scaleY, t) : yToPx(t);
    ctx.beginPath();
    ctx.moveTo(left - 4, py);
    ctx.lineTo(left, py);
    ctx.stroke();
    ctx.fillText(formatTick(t), left - 7, py + 3);
  }
  ctx.textAlign = 'center';
  ctx.fillStyle = theme.axisLabelText;
  ctx.font = '11px system-ui, sans-serif';
  ctx.fillText((spec.xAxisLabel || xParam) + (xLog ? ' (log)' : ''), left + plotWidth / 2, originY + height - 6);
  ctx.save();
  ctx.translate(originX + 12, top + plotHeight / 2);
  ctx.rotate(-Math.PI / 2);
  ctx.fillText(plotType === 'histogram' ? 'Count' : (spec.yAxisLabel || yParam) + (yLog ? ' (log)' : ''), 0, 0);
  ctx.restore();

  ctx.save();
  ctx.beginPath();
  ctx.rect(left, top, plotWidth, plotHeight);
  ctx.clip();

  const ownColor = gateNode?.color;
  if (plotType === 'histogram' && histogram) {
    const binWidth = plotWidth / histogram.nBins;
    ctx.fillStyle = ownColor ?? theme.defaultHistogramColor;
    for (let b = 0; b < histogram.nBins; b++) {
      const c = histogram.counts[b];
      if (c === 0) continue;
      const x = left + b * binWidth;
      const yTop = toRange(scaleY, c);
      ctx.fillRect(x, yTop, Math.max(1, binWidth), top + plotHeight - yTop);
    }
  } else if (plotType === 'scatter' && densityGrid) {
    const xCol = getColumn(sample, xParam);
    const yCol = getColumn(sample, yParam);
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
    if (shape.kind === 'range' && plotType === 'histogram' && shape.param === xParam) {
      drawRangeOverlay(ctx, xToPx, shape.min, shape.max, top, plotHeight, child.name, child.color ?? theme.defaultGateColor);
    } else if ((shape.kind === 'rectangle' || shape.kind === 'polygon') && plotType === 'scatter' && shape.xParam === xParam && shape.yParam === yParam) {
      drawShapeOverlay(ctx, xToPx, yToPx, shape, child.name, child.color ?? theme.defaultGateColor);
    }
  }
  if (plotType === 'scatter') {
    for (const group of collectQuadrantGroups(sample, gateNode, xParam, yParam).values()) {
      drawQuadrantCrosshair(ctx, xToPx, yToPx, group.x, group.y, group.labels, group.colors, top, plotHeight, left, plotWidth, theme);
    }
  }

  ctx.restore();

  drawStatsAnnotation(ctx, left, top, plotWidth, plotHeight, spec.statsAnnotation, gateNode, indices, sample, theme);
}

function collectQuadrantGroups(sample: Sample, gateNode: GateNode | undefined, xParam: string, yParam: string) {
  const groups = new Map<
    string,
    { x: number; y: number; labels: Partial<Record<QuadrantId, string>>; colors: Partial<Record<QuadrantId, string>> }
  >();
  for (const childId of gateNode?.childIds ?? []) {
    const child = sample.gates[childId];
    const shape = child?.shape;
    if (shape?.kind !== 'quadrant' || shape.xParam !== xParam || shape.yParam !== yParam) continue;
    const group = groups.get(shape.groupId) ?? { x: shape.x, y: shape.y, labels: {}, colors: {} };
    group.labels[shape.quadrant] = child.name;
    if (child.color) group.colors[shape.quadrant] = child.color;
    groups.set(shape.groupId, group);
  }
  return groups;
}

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
  let labelX = 0;
  let labelY = 0;
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
  ctx.fillStyle = hexToRgba(color, 0.12);
  ctx.fillRect(x1, top, x2 - x1, height);
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
  labelColors: Partial<Record<QuadrantId, string>>,
  top: number,
  plotHeight: number,
  left: number,
  plotWidth: number,
  theme: PlotTheme
) {
  const px = xPx(x);
  const py = yPx(y);
  ctx.strokeStyle = theme.defaultGateColor;
  ctx.lineWidth = 1.25;
  ctx.beginPath();
  ctx.moveTo(px, top);
  ctx.lineTo(px, top + plotHeight);
  ctx.moveTo(left, py);
  ctx.lineTo(left + plotWidth, py);
  ctx.stroke();
  ctx.font = '10px system-ui, sans-serif';
  ctx.textAlign = 'right';
  if (labels.UL) {
    ctx.fillStyle = labelColors.UL ?? theme.defaultGateColor;
    ctx.fillText(labels.UL, px - QUADRANT_LABEL_OFFSET, top + 10);
  }
  if (labels.LL) {
    ctx.fillStyle = labelColors.LL ?? theme.defaultGateColor;
    ctx.fillText(labels.LL, px - QUADRANT_LABEL_OFFSET, top + plotHeight - 4);
  }
  ctx.textAlign = 'left';
  if (labels.UR) {
    ctx.fillStyle = labelColors.UR ?? theme.defaultGateColor;
    ctx.fillText(labels.UR, px + QUADRANT_LABEL_OFFSET, top + 10);
  }
  if (labels.LR) {
    ctx.fillStyle = labelColors.LR ?? theme.defaultGateColor;
    ctx.fillText(labels.LR, px + QUADRANT_LABEL_OFFSET, top + plotHeight - 4);
  }
}

function drawStatsAnnotation(
  ctx: CanvasRenderingContext2D,
  left: number,
  top: number,
  plotWidth: number,
  plotHeight: number,
  annotation: { xFrac: number; yFrac: number } | undefined,
  gateNode: GateNode | undefined,
  indices: Uint32Array,
  sample: Sample,
  theme: PlotTheme
) {
  const frac = annotation ?? DEFAULT_STATS_ANNOTATION;
  const { percentParent, percentTotal } = gatePercentages(sample, gateNode, indices);
  const lines: string[] = [];
  if (gateNode?.parentId) lines.push(`${percentParent.toFixed(1)}% of parent`);
  lines.push(`${percentTotal.toFixed(1)}% of total`);
  ctx.font = '10px system-ui, sans-serif';
  ctx.textAlign = 'left';
  const textWidth = Math.max(...lines.map((l) => ctx.measureText(l).width));
  const boxWidth = textWidth + ANNOTATION_PADDING * 2;
  const boxHeight = lines.length * ANNOTATION_LINE_HEIGHT + ANNOTATION_PADDING * 2 - 3;
  const maxX = Math.max(left, left + plotWidth - boxWidth);
  const maxY = Math.max(top, top + plotHeight - boxHeight);
  const x = Math.min(Math.max(left + frac.xFrac * plotWidth, left), maxX);
  const y = Math.min(Math.max(top + frac.yFrac * plotHeight, top), maxY);

  ctx.fillStyle = theme.annotationBg;
  ctx.strokeStyle = theme.annotationBorder;
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
  ctx.fillStyle = theme.annotationText;
  lines.forEach((line, i) => {
    ctx.fillText(line, x + ANNOTATION_PADDING, y + ANNOTATION_PADDING + 9 + i * ANNOTATION_LINE_HEIGHT);
  });
}
