import type { Panel } from './types';

export const PANEL_WIDTH = 380;
export const PANEL_HEIGHT = 360;
export const GAP_X = 70;
export const GAP_Y = 28;
export const PADDING = 24;

/** Incremental placement for a newly created panel, without disturbing any existing (possibly manually dragged) panel. */
export function nextPanelPosition(panels: Panel[], parent: Panel | null): { x: number; y: number } {
  if (!parent) {
    const roots = panels.filter((p) => p.parentPanelId === null);
    const maxY = roots.reduce((m, p) => Math.max(m, p.y + PANEL_HEIGHT), PADDING - GAP_Y);
    return { x: PADDING, y: maxY + GAP_Y };
  }
  const siblings = panels.filter((p) => p.parentPanelId === parent.id);
  const y = siblings.length === 0 ? parent.y : siblings.reduce((m, p) => Math.max(m, p.y + PANEL_HEIGHT), 0) + GAP_Y;
  return { x: parent.x + PANEL_WIDTH + GAP_X, y };
}

/** Full recompute of every panel's position as a centered tree layout (depth -> column, DFS leaf order -> row). */
export function autoArrangeAll(panels: Panel[]): Map<string, { x: number; y: number }> {
  const byParent = new Map<string | null, Panel[]>();
  for (const p of panels) {
    const key = p.parentPanelId;
    if (!byParent.has(key)) byParent.set(key, []);
    byParent.get(key)!.push(p);
  }

  const positions = new Map<string, { x: number; y: number }>();
  let nextRow = 0;

  function place(panel: Panel, depth: number): number {
    const children = byParent.get(panel.id) ?? [];
    if (children.length === 0) {
      const row = nextRow++;
      positions.set(panel.id, { x: depth * (PANEL_WIDTH + GAP_X) + PADDING, y: row * (PANEL_HEIGHT + GAP_Y) + PADDING });
      return row;
    }
    const childRows = children.map((c) => place(c, depth + 1));
    const centerRow = (Math.min(...childRows) + Math.max(...childRows)) / 2;
    positions.set(panel.id, { x: depth * (PANEL_WIDTH + GAP_X) + PADDING, y: centerRow * (PANEL_HEIGHT + GAP_Y) + PADDING });
    return centerRow;
  }

  for (const root of byParent.get(null) ?? []) place(root, 0);
  return positions;
}
