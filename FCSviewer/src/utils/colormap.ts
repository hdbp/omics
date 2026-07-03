export type ColormapId = 'jet' | 'viridis' | 'plasma' | 'fire' | 'grayscale';

export const DEFAULT_COLORMAP: ColormapId = 'jet';

export const COLORMAP_IDS: ColormapId[] = ['jet', 'viridis', 'plasma', 'fire', 'grayscale'];

export const COLORMAP_LABELS: Record<ColormapId, string> = {
  jet: 'Rainbow',
  viridis: 'Viridis',
  plasma: 'Plasma',
  fire: 'Fire',
  grayscale: 'Grayscale',
};

const PALETTES: Record<ColormapId, [number, number, number][]> = {
  jet: [
    [0, 0, 160], // dark blue (low density)
    [0, 160, 255], // cyan
    [0, 220, 0], // green
    [255, 255, 0], // yellow
    [255, 40, 0], // red (high density)
  ],
  viridis: [
    [68, 1, 84],
    [59, 82, 139],
    [33, 145, 140],
    [94, 201, 98],
    [253, 231, 37],
  ],
  plasma: [
    [13, 8, 135],
    [126, 3, 168],
    [204, 71, 120],
    [248, 149, 64],
    [240, 249, 33],
  ],
  fire: [
    [0, 0, 0],
    [180, 0, 0],
    [255, 140, 0],
    [255, 255, 0],
    [255, 255, 255],
  ],
  grayscale: [
    [30, 30, 30],
    [90, 90, 90],
    [150, 150, 150],
    [200, 200, 200],
    [240, 240, 240],
  ],
};

/** Maps a density value in [0,1] to an "rgb(...)" string, using the given palette (default the classic "jet" gradient). */
export function densityColor(t: number, colormap: ColormapId = DEFAULT_COLORMAP): string {
  const stops = PALETTES[colormap] ?? PALETTES.jet;
  const clamped = Math.max(0, Math.min(1, t));
  const scaled = clamped * (stops.length - 1);
  const i = Math.min(stops.length - 2, Math.floor(scaled));
  const frac = scaled - i;
  const [r1, g1, b1] = stops[i];
  const [r2, g2, b2] = stops[i + 1];
  const r = Math.round(r1 + (r2 - r1) * frac);
  const g = Math.round(g1 + (g2 - g1) * frac);
  const b = Math.round(b1 + (b2 - b1) * frac);
  return `rgb(${r},${g},${b})`;
}

/** Converts a "#rrggbb" hex color into an rgba() string with the given alpha. */
export function hexToRgba(hex: string, alpha: number): string {
  const match = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
  if (!match) return `rgba(46, 230, 166, ${alpha})`;
  const r = parseInt(match[1], 16);
  const g = parseInt(match[2], 16);
  const b = parseInt(match[3], 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}
