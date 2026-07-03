export interface FontFamilyOption {
  id: string;
  label: string;
}

/** Font families offered in the panel toolbar; the id is the literal CSS font-family value used in ctx.font. */
export const FONT_FAMILY_OPTIONS: FontFamilyOption[] = [
  { id: 'system-ui, sans-serif', label: 'System UI' },
  { id: 'Arial, Helvetica, sans-serif', label: 'Arial' },
  { id: 'Georgia, "Times New Roman", serif', label: 'Georgia' },
  { id: '"Times New Roman", Times, serif', label: 'Times New Roman' },
  { id: '"Courier New", Courier, monospace', label: 'Courier New' },
  { id: 'Verdana, Geneva, sans-serif', label: 'Verdana' },
];

export const DEFAULT_FONT_FAMILY = FONT_FAMILY_OPTIONS[0].id;
/** Base size (px) for axis labels; tick/quadrant/annotation text render 1px smaller. */
export const DEFAULT_FONT_SIZE = 11;
export const MIN_FONT_SIZE = 8;
export const MAX_FONT_SIZE = 20;

export interface PanelFontSpec {
  labelFont: string;
  tickFont: string;
}

/** Resolves a panel/layout item's font choice (or the defaults) into ready-to-use ctx.font strings. */
export function resolvePanelFont(fontFamily: string | undefined, fontSize: number | undefined): PanelFontSpec {
  const family = fontFamily || DEFAULT_FONT_FAMILY;
  const baseSize = fontSize ?? DEFAULT_FONT_SIZE;
  return {
    labelFont: `${baseSize}px ${family}`,
    tickFont: `${Math.max(7, baseSize - 1)}px ${family}`,
  };
}
