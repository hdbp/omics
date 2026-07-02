export interface LinearScale {
  domainMin: number;
  domainMax: number;
  rangeMin: number;
  rangeMax: number;
}

export function makeScale(domainMin: number, domainMax: number, rangeMin: number, rangeMax: number): LinearScale {
  // Guard against a degenerate (zero-width) domain, which would otherwise
  // produce NaN/Infinity pixel coordinates.
  if (domainMax - domainMin < 1e-9) {
    domainMax = domainMin + 1;
  }
  return { domainMin, domainMax, rangeMin, rangeMax };
}

export function toRange(scale: LinearScale, value: number): number {
  const t = (value - scale.domainMin) / (scale.domainMax - scale.domainMin);
  return scale.rangeMin + t * (scale.rangeMax - scale.rangeMin);
}

export function toDomain(scale: LinearScale, value: number): number {
  const t = (value - scale.rangeMin) / (scale.rangeMax - scale.rangeMin);
  return scale.domainMin + t * (scale.domainMax - scale.domainMin);
}

/**
 * Maps a raw parameter value into "plot space": identity when linear, or a
 * log10 transform (floored at 1, since flow data is ~always non-negative and
 * log(0) is undefined) when log. Gate shapes are always stored in raw data
 * space; only the pixel mapping goes through this.
 */
export function dataToPlotValue(raw: number, log: boolean): number {
  if (!log) return raw;
  return Math.log10(Math.max(raw, 1));
}

export function plotValueToData(plotValue: number, log: boolean): number {
  if (!log) return plotValue;
  return 10 ** plotValue;
}

/** Decade tick values (1, 10, 100, ...) up to maxRaw, for a log-scaled axis. */
export function logTicks(maxRaw: number): number[] {
  const ticks: number[] = [];
  for (let v = 1; v <= maxRaw; v *= 10) ticks.push(v);
  if (ticks.length === 0) ticks.push(1);
  return ticks;
}

export function niceTicks(min: number, max: number, count = 5): number[] {
  if (max <= min) return [min];
  const span = max - min;
  const rawStep = span / count;
  const magnitude = 10 ** Math.floor(Math.log10(rawStep));
  const residual = rawStep / magnitude;
  let step: number;
  if (residual > 5) step = 10 * magnitude;
  else if (residual > 2) step = 5 * magnitude;
  else if (residual > 1) step = 2 * magnitude;
  else step = magnitude;

  const ticks: number[] = [];
  const start = Math.ceil(min / step) * step;
  for (let v = start; v <= max + step * 1e-6; v += step) {
    ticks.push(Math.round(v / step) * step);
  }
  return ticks;
}
