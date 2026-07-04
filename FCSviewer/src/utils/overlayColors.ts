/**
 * A fixed set of visually distinct flat colors for overlaying multiple samples'
 * populations on one plot. Deliberately separate from the pseudocolor density
 * palettes (colormap.ts) — those shade a single population by local density, which
 * is meaningless once several samples share one plot; overlays instead need one
 * unambiguous, maximally distinguishable color per sample.
 */
export const OVERLAY_COLOR_PALETTE: string[] = [
  '#4f8dff',
  '#ff9f1c',
  '#2ee6a6',
  '#ff5c8a',
  '#c792ea',
  '#ffd166',
  '#06d6a0',
  '#ef476f',
  '#8ecae6',
  '#f4a261',
];

/** Picks the first palette color not already in use by a sibling layer, cycling if the palette is exhausted. */
export function pickOverlayColor(usedColors: (string | undefined)[]): string {
  const used = new Set(usedColors.filter((c): c is string => Boolean(c)));
  const free = OVERLAY_COLOR_PALETTE.find((c) => !used.has(c));
  return free ?? OVERLAY_COLOR_PALETTE[used.size % OVERLAY_COLOR_PALETTE.length];
}
