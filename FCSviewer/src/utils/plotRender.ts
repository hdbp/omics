import { getColumn, type Sample } from '../state/types';
import { getGateEventIndices } from '../gating/gateEval';
import { gatePercentages, collectQuadrantGroups, type QuadrantStat } from '../gating/gateStats';
import type { GateNode, GateShape, QuadrantId } from '../gating/gateTypes';
import { makeScale, toRange, niceTicks, logTicks, dataToPlotValue, type LinearScale } from './scale';
import { densityColor, hexToRgba, DEFAULT_COLORMAP, type ColormapId } from './colormap';
import { resolvePanelFont } from './fonts';
import type { PlotTheme } from './theme';

const MARGIN = { top: 16, right: 20, bottom: 42, left: 58 };
const QUADRANT_LABEL_OFFSET = 6;
const QUADRANT_STATS_LINE_HEIGHT = 12;
const ANNOTATION_PADDING = 6;
const ANNOTATION_LINE_HEIGHT = 13;
const DEFAULT_STATS_ANNOTATION = { xFrac: 0.03, yFrac: 0.06 };

function formatQuadrantStats(stat: QuadrantStat): string {
  return `${stat.count.toLocaleString()} (${stat.percentParent.toFixed(1)}%)`;
}

function paramRange(sample: Sample, name: string): number {
  return sample.parameters.find((p) => p.name === name)?.range ?? 1;
}

function formatTick(v: number): string {
  if (Math.abs(v) >= 1000) return `${Math.round(v / 1000)}k`;
  return `${Math.round(v)}`;
}

/** A resolved overlay layer (its Sample object already looked up), for drawing another sample's population on top of the base plot. */
export interface ResolvedOverlay {
  sample: Sample;
  gateId: string;
  label: string;
  color: string;
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
  colormap?: ColormapId;
  fontFamily?: string;
  fontSize?: number;
  /** Other samples' populations to draw on top of this one (same axes), each in its own flat color. */
  overlays?: ResolvedOverlay[];
  /** Flat color for the base sample's own layer once overlays are present (set alongside overlays). */
  overlayBaseColor?: string;
  /** Label for the base sample's own layer, shown in the legend when overlays are present. */
  baseLabel?: string;
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

  const nBins = 150;
  const xPlotMinForHist = dataToPlotValue(xLog ? 1 : 0, xLog);
  const xSpanForHist = dataToPlotValue(xDomainMax, xLog) - xPlotMinForHist || 1;

  let histogram: { counts: Uint32Array; nBins: number; max: number } | null = null;
  if (plotType === 'histogram') {
    const counts = computeHistCounts(getColumn(sample, xParam), indices, xLog, xPlotMinForHist, xSpanForHist, nBins);
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

  const { labelFont, tickFont } = resolvePanelFont(spec.fontFamily, spec.fontSize);

  ctx.strokeStyle = theme.plotBorder;
  ctx.lineWidth = 1;
  ctx.strokeRect(left, top, plotWidth, plotHeight);

  ctx.fillStyle = theme.tickText;
  ctx.font = tickFont;
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
  ctx.font = labelFont;
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

  const overlays = spec.overlays ?? [];
  const overlayMode = overlays.length > 0;
  const ownColor = spec.overlayBaseColor ?? gateNode?.color;
  if (plotType === 'histogram' && histogram) {
    if (overlayMode) {
      drawHistogramOutline(ctx, histogram.counts, histogram.nBins, scaleY, left, plotWidth, top, plotHeight, ownColor ?? theme.defaultHistogramColor);
    } else {
      const binWidth = plotWidth / histogram.nBins;
      ctx.fillStyle = ownColor ?? theme.defaultHistogramColor;
      for (let b = 0; b < histogram.nBins; b++) {
        const c = histogram.counts[b];
        if (c === 0) continue;
        const x = left + b * binWidth;
        const yTop = toRange(scaleY, c);
        ctx.fillRect(x, yTop, Math.max(1, binWidth), top + plotHeight - yTop);
      }
    }
  } else if (plotType === 'scatter' && densityGrid) {
    const xCol = getColumn(sample, xParam);
    const yCol = getColumn(sample, yParam);
    if (ownColor) ctx.fillStyle = overlayMode ? hexToRgba(ownColor, 0.6) : ownColor;
    for (let i = 0; i < indices.length; i++) {
      const idx = indices[i];
      const px = xToPx(xCol[idx]);
      const py = yToPx(yCol[idx]);
      if (!ownColor) {
        const count = densityGrid.counts[densityGrid.binOf[i]];
        const t = Math.log1p(count) / Math.log1p(densityGrid.maxCount);
        ctx.fillStyle = densityColor(t, spec.colormap ?? DEFAULT_COLORMAP);
      }
      ctx.fillRect(px - 1, py - 1, 2, 2);
    }
  }

  for (const ov of overlays) {
    const xOk = ov.sample.paramIndex[xParam] !== undefined;
    const yOk = plotType === 'histogram' || ov.sample.paramIndex[yParam] !== undefined;
    if (!xOk || !yOk) continue;
    const ovIndices = getGateEventIndices(ov.sample, ov.gateId);
    if (plotType === 'histogram') {
      const ovCounts = computeHistCounts(getColumn(ov.sample, xParam), ovIndices, xLog, xPlotMinForHist, xSpanForHist, nBins);
      drawHistogramOutline(ctx, ovCounts, nBins, scaleY, left, plotWidth, top, plotHeight, ov.color);
    } else {
      const xCol = getColumn(ov.sample, xParam);
      const yCol = getColumn(ov.sample, yParam);
      ctx.fillStyle = hexToRgba(ov.color, 0.6);
      for (let i = 0; i < ovIndices.length; i++) {
        const idx = ovIndices[i];
        const px = xToPx(xCol[idx]);
        const py = yToPx(yCol[idx]);
        ctx.fillRect(px - 1, py - 1, 2, 2);
      }
    }
  }

  for (const childId of gateNode?.childIds ?? []) {
    const child = sample.gates[childId];
    const shape = child.shape;
    if (!shape) continue;
    if (shape.kind === 'range' && plotType === 'histogram' && shape.param === xParam) {
      drawRangeOverlay(ctx, xToPx, shape.min, shape.max, top, plotHeight, child.name, child.color ?? theme.defaultGateColor, tickFont);
    } else if ((shape.kind === 'rectangle' || shape.kind === 'polygon') && plotType === 'scatter' && shape.xParam === xParam && shape.yParam === yParam) {
      drawShapeOverlay(ctx, xToPx, yToPx, shape, child.name, child.color ?? theme.defaultGateColor, tickFont);
    }
  }
  if (plotType === 'scatter') {
    for (const group of collectQuadrantGroups(sample, gateNode, xParam, yParam).values()) {
      drawQuadrantCrosshair(ctx, xToPx, yToPx, group.x, group.y, group.labels, group.colors, group.stats, top, plotHeight, left, plotWidth, theme, tickFont);
    }
  }

  ctx.restore();

  if (overlayMode) {
    drawOverlayLegend(ctx, left, top, plotWidth, spec.baseLabel ?? 'This panel', ownColor ?? theme.defaultGateColor, overlays, theme, tickFont);
  }

  drawStatsAnnotation(ctx, left, top, plotWidth, plotHeight, spec.statsAnnotation, gateNode, indices, sample, theme, tickFont);
}

/** Bins already-log/linear-transformed event values into `nBins` histogram counts over [plotMin, plotMin+span). */
function computeHistCounts(
  col: Float32Array,
  indices: Uint32Array,
  xLog: boolean,
  plotMin: number,
  span: number,
  nBins: number
): Uint32Array {
  const counts = new Uint32Array(nBins);
  for (let i = 0; i < indices.length; i++) {
    const v = dataToPlotValue(col[indices[i]], xLog);
    let bin = Math.floor(((v - plotMin) / span) * nBins);
    if (bin < 0) bin = 0;
    if (bin >= nBins) bin = nBins - 1;
    counts[bin]++;
  }
  return counts;
}

/** Draws a histogram as a stepped outline (no fill) rather than solid bars, so multiple overlaid samples' histograms stay individually readable. */
function drawHistogramOutline(
  ctx: CanvasRenderingContext2D,
  counts: Uint32Array,
  nBins: number,
  scaleY: LinearScale,
  left: number,
  plotWidth: number,
  top: number,
  plotHeight: number,
  color: string
): void {
  const binWidth = plotWidth / nBins;
  ctx.strokeStyle = color;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.moveTo(left, top + plotHeight);
  for (let b = 0; b < nBins; b++) {
    const x = left + b * binWidth;
    const y = toRange(scaleY, counts[b]);
    ctx.lineTo(x, y);
    ctx.lineTo(x + binWidth, y);
  }
  ctx.lineTo(left + plotWidth, top + plotHeight);
  ctx.stroke();
}

/** Small color-swatch + label key (top-right of the plot) identifying which sample each overlay layer belongs to. */
function drawOverlayLegend(
  ctx: CanvasRenderingContext2D,
  left: number,
  top: number,
  plotWidth: number,
  baseLabel: string,
  baseColor: string,
  overlays: ResolvedOverlay[],
  theme: PlotTheme,
  font: string
): void {
  const rows = [{ label: baseLabel, color: baseColor }, ...overlays.map((o) => ({ label: o.label, color: o.color }))];
  ctx.font = font;
  ctx.textAlign = 'left';
  const swatch = 8;
  const rowHeight = 13;
  const padding = 6;
  const textWidth = Math.max(...rows.map((r) => ctx.measureText(r.label).width));
  const boxWidth = swatch + 6 + textWidth + padding * 2;
  const boxHeight = rows.length * rowHeight + padding * 2 - 3;
  const x = Math.max(left, left + plotWidth - boxWidth - 4);
  const y = top + 4;

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
  rows.forEach((r, i) => {
    const rowY = y + padding + i * rowHeight;
    ctx.fillStyle = r.color;
    ctx.fillRect(x + padding, rowY + 2, swatch, swatch);
    ctx.fillStyle = theme.annotationText;
    ctx.fillText(r.label, x + padding + swatch + 6, rowY + 9);
  });
}

function drawShapeOverlay(
  ctx: CanvasRenderingContext2D,
  xPx: (raw: number) => number,
  yPx: (raw: number) => number,
  shape: GateShape,
  label: string,
  color: string,
  font: string
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
    ctx.font = font;
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
  font: string
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
    ctx.font = font;
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
  stats: Partial<Record<QuadrantId, QuadrantStat>>,
  top: number,
  plotHeight: number,
  left: number,
  plotWidth: number,
  theme: PlotTheme,
  font: string
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
  ctx.font = font;
  ctx.textAlign = 'right';
  if (labels.UL) {
    ctx.fillStyle = labelColors.UL ?? theme.defaultGateColor;
    ctx.fillText(labels.UL, px - QUADRANT_LABEL_OFFSET, top + 10);
    if (stats.UL) ctx.fillText(formatQuadrantStats(stats.UL), px - QUADRANT_LABEL_OFFSET, top + 10 + QUADRANT_STATS_LINE_HEIGHT);
  }
  if (labels.LL) {
    ctx.fillStyle = labelColors.LL ?? theme.defaultGateColor;
    if (stats.LL) ctx.fillText(formatQuadrantStats(stats.LL), px - QUADRANT_LABEL_OFFSET, top + plotHeight - 4 - QUADRANT_STATS_LINE_HEIGHT);
    ctx.fillText(labels.LL, px - QUADRANT_LABEL_OFFSET, top + plotHeight - 4);
  }
  ctx.textAlign = 'left';
  if (labels.UR) {
    ctx.fillStyle = labelColors.UR ?? theme.defaultGateColor;
    ctx.fillText(labels.UR, px + QUADRANT_LABEL_OFFSET, top + 10);
    if (stats.UR) ctx.fillText(formatQuadrantStats(stats.UR), px + QUADRANT_LABEL_OFFSET, top + 10 + QUADRANT_STATS_LINE_HEIGHT);
  }
  if (labels.LR) {
    ctx.fillStyle = labelColors.LR ?? theme.defaultGateColor;
    if (stats.LR) ctx.fillText(formatQuadrantStats(stats.LR), px + QUADRANT_LABEL_OFFSET, top + plotHeight - 4 - QUADRANT_STATS_LINE_HEIGHT);
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
  theme: PlotTheme,
  font: string
) {
  const frac = annotation ?? DEFAULT_STATS_ANNOTATION;
  const { percentParent, percentTotal } = gatePercentages(sample, gateNode, indices);
  const lines: string[] = [];
  if (gateNode?.parentId) lines.push(`${percentParent.toFixed(1)}% of parent`);
  lines.push(`${percentTotal.toFixed(1)}% of total`);
  ctx.font = font;
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
