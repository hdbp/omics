import { erf, gaussianDensity, nelderMead } from '../utils/numeric';

export type CellCycleMethod = 'manual' | 'auto';

/** Raw fitted-model parameters, kept alongside the derived stats so the model curves can be redrawn without re-fitting. */
export interface CellCycleModelParams {
  mu1: number;
  sigma1: number;
  sigma2: number;
  a1: number;
  a2: number;
  aS: number;
  sigmaS: number;
}

export interface CellCycleFitResult {
  params: CellCycleModelParams;
  g1Mean: number;
  g1CV: number;
  g2Mean: number;
  g2CV: number;
  g1Fraction: number;
  sFraction: number;
  g2Fraction: number;
  /** G2/M mean ÷ G1 mean; should be close to 2.0 for a well-behaved diploid histogram. */
  g2g1Ratio: number;
  /** Reduced chi-square goodness of fit; lower is better, ~1 is a good fit. */
  rcs: number;
}

/** Persisted on a Panel/LayoutItem once cell-cycle analysis has been set up for that histogram. */
export interface CellCycleAnalysis {
  method: CellCycleMethod;
  /** Manual-mode phase boundaries, in data units along the histogram's own X parameter. */
  boundaries?: { g1s: number; sg2m: number };
  /** Auto-fit model result, present once "Run fit" has produced one. */
  fit?: CellCycleFitResult;
}

/** G1 phase component of the model at `x` (a Gaussian centered on the G1 peak). */
export function evaluateG1(x: number, p: CellCycleModelParams): number {
  return p.a1 * gaussianDensity(x, p.mu1, p.sigma1);
}

/** G2/M phase component at `x` (a Gaussian centered at exactly 2x the G1 mean — the classic diploid assumption). */
export function evaluateG2(x: number, p: CellCycleModelParams): number {
  return p.a2 * gaussianDensity(x, 2 * p.mu1, p.sigma2);
}

/**
 * S-phase component at `x`: a Gaussian-broadened "bridge" between the G1 and
 * G2/M means, built as the difference of two error-function ramps — a common
 * simplification of the full Dean-Jett-Fox polynomial-convolution model that
 * still captures the shape of the S-phase shoulder well for typical diploid
 * histograms.
 */
export function evaluateS(x: number, p: CellCycleModelParams): number {
  const mu2 = 2 * p.mu1;
  const bridge = 0.5 * (erf((x - p.mu1) / (Math.SQRT2 * p.sigmaS)) - erf((x - mu2) / (Math.SQRT2 * p.sigmaS)));
  return Math.max(0, p.aS * bridge);
}

export function evaluateTotal(x: number, p: CellCycleModelParams): number {
  return evaluateG1(x, p) + evaluateG2(x, p) + evaluateS(x, p);
}

function smoothCounts(counts: ArrayLike<number>, window = 3): Float64Array {
  const n = counts.length;
  const out = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    let sum = 0;
    let count = 0;
    for (let k = -window; k <= window; k++) {
      const j = i + k;
      if (j >= 0 && j < n) {
        sum += counts[j];
        count++;
      }
    }
    out[i] = sum / count;
  }
  return out;
}

function findLocalMaxima(values: Float64Array, fromIndex: number, toIndex: number): number[] {
  const peaks: number[] = [];
  for (let i = Math.max(1, fromIndex); i < Math.min(values.length - 1, toIndex); i++) {
    if (values[i] > 0 && values[i] >= values[i - 1] && values[i] > values[i + 1]) peaks.push(i);
  }
  peaks.sort((a, b) => values[b] - values[a]);
  return peaks;
}

/**
 * Seeds initial G1/G2M peak-channel guesses from a DNA-content histogram: the
 * tallest smoothed peak in the first ~70% of the range is assumed to be G1,
 * and the tallest peak found between 1.5x-2.5x its channel is assumed to be
 * G2/M (falling back to a plain 2x guess if no such peak stands out).
 */
export function seedCellCyclePeaks(counts: ArrayLike<number>): { g1Bin: number; g2Bin: number } {
  const nBins = counts.length;
  const smoothed = smoothCounts(counts);
  const g1Candidates = findLocalMaxima(smoothed, 0, Math.floor(nBins * 0.7));
  const g1Bin = g1Candidates.length > 0 ? g1Candidates[0] : Math.floor(nBins * 0.25);
  const g2Candidates = findLocalMaxima(smoothed, Math.floor(g1Bin * 1.5), Math.min(nBins, Math.floor(g1Bin * 2.5) + 1));
  const g2Bin = g2Candidates.length > 0 ? g2Candidates[0] : Math.min(nBins - 1, g1Bin * 2);
  return { g1Bin, g2Bin };
}

/**
 * Fits the simplified Watson-pragmatic-style model (G1 + G2/M Gaussians, G2/M
 * mean fixed at 2x the G1 mean, plus a single-amplitude S-phase bridge) to a
 * binned DNA-content histogram via Nelder-Mead least squares, seeded from
 * `seedCellCyclePeaks`.
 */
export function fitCellCycle(counts: ArrayLike<number>, binCenters: ArrayLike<number>, seed: { g1Bin: number; g2Bin: number }): CellCycleFitResult {
  const n = counts.length;
  let total = 0;
  for (let i = 0; i < n; i++) total += counts[i];
  total = total || 1;

  const mu1_0 = binCenters[seed.g1Bin] || 1;
  const binWidth = n > 1 ? binCenters[1] - binCenters[0] : 1;
  const sigma1_0 = Math.max(binWidth * 2, mu1_0 * 0.06);
  const peak1 = counts[seed.g1Bin] || 1;
  const peak2 = counts[seed.g2Bin] || peak1 * 0.3;
  const gaussArea = (peakHeight: number, sigma: number) => peakHeight * sigma * Math.sqrt(2 * Math.PI);

  // params: [mu1, sigma1, sigma2, a1, a2, aS, sigmaS]
  const initial = [mu1_0, sigma1_0, sigma1_0 * 1.2, gaussArea(peak1, sigma1_0), gaussArea(peak2, sigma1_0 * 1.2), total * 0.12, sigma1_0];

  function modelAt(x: number, params: number[]): number {
    const [mu1, sigma1, sigma2, a1, a2, aS, sigmaS] = params;
    return evaluateTotal(x, { mu1, sigma1, sigma2, a1, a2, aS, sigmaS });
  }

  function cost(params: number[]): number {
    const [mu1, sigma1, sigma2, a1, a2, aS, sigmaS] = params;
    if (mu1 <= 0 || sigma1 <= 0 || sigma2 <= 0 || sigmaS <= 0 || a1 < 0 || a2 < 0 || aS < 0) return Number.POSITIVE_INFINITY;
    let sse = 0;
    for (let i = 0; i < n; i++) {
      const diff = modelAt(binCenters[i], params) - counts[i];
      sse += diff * diff;
    }
    return sse;
  }

  const fitted = nelderMead(cost, initial, { maxIter: 4000 });
  const [mu1, sigma1, sigma2, a1, a2, aS, sigmaS] = fitted;
  const params: CellCycleModelParams = { mu1, sigma1, sigma2, a1, a2, aS, sigmaS };
  const mu2 = 2 * mu1;

  let g1Sum = 0;
  let g2Sum = 0;
  let sSum = 0;
  let chiSq = 0;
  for (let i = 0; i < n; i++) {
    const x = binCenters[i];
    const g1v = evaluateG1(x, params);
    const g2v = evaluateG2(x, params);
    const sv = evaluateS(x, params);
    g1Sum += g1v;
    g2Sum += g2v;
    sSum += sv;
    const predicted = g1v + g2v + sv;
    const diff = counts[i] - predicted;
    chiSq += (diff * diff) / Math.max(predicted, 1);
  }
  const fittedTotal = g1Sum + g2Sum + sSum || 1;
  const dof = Math.max(1, n - 7);

  return {
    params,
    g1Mean: mu1,
    g1CV: mu1 !== 0 ? (sigma1 / mu1) * 100 : 0,
    g2Mean: mu2,
    g2CV: mu2 !== 0 ? (sigma2 / mu2) * 100 : 0,
    g1Fraction: g1Sum / fittedTotal,
    sFraction: sSum / fittedTotal,
    g2Fraction: g2Sum / fittedTotal,
    g2g1Ratio: mu1 !== 0 ? mu2 / mu1 : 0,
    rcs: chiSq / dof,
  };
}
