/** Abramowitz-Stegun rational approximation of the error function (max error ~1.5e-7). No numeric-library dependency needed for the one place we use it (cell-cycle fitting). */
export function erf(x: number): number {
  const sign = x < 0 ? -1 : 1;
  const ax = Math.abs(x);
  const a1 = 0.254829592;
  const a2 = -0.284496736;
  const a3 = 1.421413741;
  const a4 = -1.453152027;
  const a5 = 1.061405429;
  const p = 0.3275911;
  const t = 1 / (1 + p * ax);
  const y = 1 - (((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t) * Math.exp(-ax * ax);
  return sign * y;
}

/** Gaussian probability density, scaled so its peak height (not its integral) is easy to reason about relative to raw histogram counts. */
export function gaussianDensity(x: number, mean: number, sigma: number): number {
  if (sigma <= 0) return 0;
  const z = (x - mean) / sigma;
  return Math.exp(-0.5 * z * z) / (sigma * Math.sqrt(2 * Math.PI));
}

/**
 * Minimizes `fn` over a starting point via the Nelder-Mead simplex method (no
 * derivatives needed) — a compact, dependency-free choice for the small
 * (~7-parameter) nonlinear least-squares fits cell-cycle analysis needs.
 * Returns the best parameter vector found within `maxIter` iterations.
 */
export function nelderMead(fn: (params: number[]) => number, initial: number[], options?: { maxIter?: number; tol?: number }): number[] {
  const n = initial.length;
  const maxIter = options?.maxIter ?? 3000;
  const tol = options?.tol ?? 1e-10;
  const alpha = 1;
  const gamma = 2;
  const rho = 0.5;
  const sigma = 0.5;

  const simplex: { p: number[]; f: number }[] = [{ p: initial.slice(), f: fn(initial) }];
  for (let i = 0; i < n; i++) {
    const p = initial.slice();
    p[i] += p[i] !== 0 ? p[i] * 0.15 : 0.15;
    simplex.push({ p, f: fn(p) });
  }

  for (let iter = 0; iter < maxIter; iter++) {
    simplex.sort((a, b) => a.f - b.f);
    if (Math.abs(simplex[n].f - simplex[0].f) < tol) break;

    const centroid = new Array(n).fill(0);
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) centroid[j] += simplex[i].p[j] / n;
    }

    const reflected = centroid.map((c, j) => c + alpha * (c - simplex[n].p[j]));
    const fReflected = fn(reflected);

    if (fReflected < simplex[0].f) {
      const expanded = centroid.map((c, j) => c + gamma * (reflected[j] - c));
      const fExpanded = fn(expanded);
      simplex[n] = fExpanded < fReflected ? { p: expanded, f: fExpanded } : { p: reflected, f: fReflected };
    } else if (fReflected < simplex[n - 1].f) {
      simplex[n] = { p: reflected, f: fReflected };
    } else {
      const contracted = centroid.map((c, j) => c + rho * (simplex[n].p[j] - c));
      const fContracted = fn(contracted);
      if (fContracted < simplex[n].f) {
        simplex[n] = { p: contracted, f: fContracted };
      } else {
        for (let i = 1; i <= n; i++) {
          simplex[i].p = simplex[i].p.map((v, j) => simplex[0].p[j] + sigma * (v - simplex[0].p[j]));
          simplex[i].f = fn(simplex[i].p);
        }
      }
    }
  }

  simplex.sort((a, b) => a.f - b.f);
  return simplex[0].p;
}
