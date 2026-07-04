import type { Panel, LayoutItem } from './types';

export const DEFAULT_PANEL_WIDTH = 380;
export const DEFAULT_PANEL_HEIGHT = 360;
export const MIN_PANEL_WIDTH = 260;
export const MIN_PANEL_HEIGHT = 220;
// Capped so a panel's own resize handle can never be dragged so far that it ends up
// scrolled out of reach of its workspace's viewport (double-click the handle also
// resets a panel back to the default size, as a second way out).
export const MAX_PANEL_WIDTH = 900;
export const MAX_PANEL_HEIGHT = 750;
export const GAP_X = 70;
export const GAP_Y = 28;
export const PADDING = 24;

/** Incremental placement for a newly created panel, without disturbing any existing (possibly manually dragged/resized) panel. */
export function nextPanelPosition(panels: Panel[], parent: Panel | null): { x: number; y: number } {
  if (!parent) {
    const roots = panels.filter((p) => p.parentPanelId === null);
    const maxY = roots.reduce((m, p) => Math.max(m, p.y + p.height), PADDING - GAP_Y);
    return { x: PADDING, y: maxY + GAP_Y };
  }
  const siblings = panels.filter((p) => p.parentPanelId === parent.id);
  const y = siblings.length === 0 ? parent.y : siblings.reduce((m, p) => Math.max(m, p.y + p.height), 0) + GAP_Y;
  return { x: parent.x + parent.width + GAP_X, y };
}

/**
 * Full recompute of every panel's position as a centered tree layout: depth
 * determines the column (sized to the widest panel at that depth), and
 * depth-first leaf order determines vertical placement (each leaf reserves
 * its own actual height; parents center over their children's span).
 */
export function autoArrangeAll(panels: Panel[]): Map<string, { x: number; y: number }> {
  const byParent = new Map<string | null, Panel[]>();
  for (const p of panels) {
    const key = p.parentPanelId;
    if (!byParent.has(key)) byParent.set(key, []);
    byParent.get(key)!.push(p);
  }

  const colWidth = new Map<number, number>();
  function measureDepths(panel: Panel, depth: number) {
    colWidth.set(depth, Math.max(colWidth.get(depth) ?? 0, panel.width));
    for (const child of byParent.get(panel.id) ?? []) measureDepths(child, depth + 1);
  }
  for (const root of byParent.get(null) ?? []) measureDepths(root, 0);

  const maxDepth = colWidth.size === 0 ? 0 : Math.max(...colWidth.keys());
  const colX = new Map<number, number>();
  let cursorX = PADDING;
  for (let d = 0; d <= maxDepth; d++) {
    colX.set(d, cursorX);
    cursorX += (colWidth.get(d) ?? DEFAULT_PANEL_WIDTH) + GAP_X;
  }

  const positions = new Map<string, { x: number; y: number }>();
  let cursorY = PADDING;

  function place(panel: Panel, depth: number): number {
    const x = colX.get(depth) ?? PADDING;
    const children = byParent.get(panel.id) ?? [];
    if (children.length === 0) {
      const y = cursorY;
      cursorY += panel.height + GAP_Y;
      positions.set(panel.id, { x, y });
      return y + panel.height / 2;
    }
    const childCenters = children.map((c) => place(c, depth + 1));
    const center = (Math.min(...childCenters) + Math.max(...childCenters)) / 2;
    const y = center - panel.height / 2;
    positions.set(panel.id, { x, y });
    return center;
  }

  for (const root of byParent.get(null) ?? []) place(root, 0);
  return positions;
}

/** Incremental placement for a newly added layout item: appended to the end of the current row. */
export function nextLayoutPosition(items: LayoutItem[]): { x: number; y: number } {
  if (items.length === 0) return { x: PADDING, y: PADDING };
  const last = items[items.length - 1];
  return { x: last.x + last.width + GAP_X, y: last.y };
}

/** Grid re-flow for the Layout collage: items are unrelated (no hierarchy), so this just wraps rows. */
export function autoArrangeLayoutGrid(items: LayoutItem[], columns = 3): Map<string, { x: number; y: number }> {
  const positions = new Map<string, { x: number; y: number }>();
  let cursorY = PADDING;
  for (let start = 0; start < items.length; start += columns) {
    const rowItems = items.slice(start, start + columns);
    const rowHeight = Math.max(...rowItems.map((it) => it.height));
    let cursorX = PADDING;
    for (const it of rowItems) {
      positions.set(it.id, { x: cursorX, y: cursorY });
      cursorX += it.width + GAP_X;
    }
    cursorY += rowHeight + GAP_Y;
  }
  return positions;
}
