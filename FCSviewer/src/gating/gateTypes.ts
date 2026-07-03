export interface Point {
  x: number;
  y: number;
}

export interface RectangleGateShape {
  kind: 'rectangle';
  xParam: string;
  yParam: string;
  x1: number;
  y1: number;
  x2: number;
  y2: number;
}

export interface PolygonGateShape {
  kind: 'polygon';
  xParam: string;
  yParam: string;
  points: Point[];
}

/** A 1-D interval gate, used on histogram plots. */
export interface RangeGateShape {
  kind: 'range';
  param: string;
  min: number;
  max: number;
}

export type QuadrantId = 'UL' | 'UR' | 'LL' | 'LR';

/**
 * One quarter of a quadrant gate: a crosshair at (x, y) splits the plot into
 * four unbounded regions. All four siblings from one placement share
 * `groupId` and the same (x, y), so dragging one moves all four together.
 */
export interface QuadrantGateShape {
  kind: 'quadrant';
  xParam: string;
  yParam: string;
  x: number;
  y: number;
  quadrant: QuadrantId;
  groupId: string;
}

export type GateShape = RectangleGateShape | PolygonGateShape | RangeGateShape | QuadrantGateShape;

export interface GateNode {
  id: string;
  name: string;
  parentId: string | null;
  shape: GateShape | null; // null only for the synthetic root "All Events" node
  childIds: string[];
}

export const ROOT_GATE_ID = 'root';

export function makeRootGate(): GateNode {
  return { id: ROOT_GATE_ID, name: 'All Events', parentId: null, shape: null, childIds: [] };
}
