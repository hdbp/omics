/** Classic "jet"-style pseudocolor gradient used for flow cytometry density plots. */
const STOPS: [number, number, number][] = [
  [0, 0, 160], // dark blue (low density)
  [0, 160, 255], // cyan
  [0, 220, 0], // green
  [255, 255, 0], // yellow
  [255, 40, 0], // red (high density)
];

export function densityColor(t: number): string {
  const clamped = Math.max(0, Math.min(1, t));
  const scaled = clamped * (STOPS.length - 1);
  const i = Math.min(STOPS.length - 2, Math.floor(scaled));
  const frac = scaled - i;
  const [r1, g1, b1] = STOPS[i];
  const [r2, g2, b2] = STOPS[i + 1];
  const r = Math.round(r1 + (r2 - r1) * frac);
  const g = Math.round(g1 + (g2 - g1) * frac);
  const b = Math.round(b1 + (b2 - b1) * frac);
  return `rgb(${r},${g},${b})`;
}
