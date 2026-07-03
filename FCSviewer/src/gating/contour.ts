import type { Point } from './gateTypes';

/**
 * Traces density contour lines through a scalar grid using marching squares,
 * powering the "contour gate" tool: click a density region and its outline
 * (at the current sensitivity) becomes a regular polygon gate. Grid values
 * are read as if the grid were padded by a zero border, so contours near the
 * edge of the plotted range still close into loops instead of running off.
 *
 * Coordinates are returned in fractional grid-cell units (0..gridN in both
 * axes, cell (0,0) at the grid's top-left corner) — callers map these back
 * to data units the same way the density grid itself was built.
 */
export function marchingSquares(counts: ArrayLike<number>, gridN: number, threshold: number): Point[][] {
  const at = (gx: number, gy: number): number => {
    if (gx < 0 || gy < 0 || gx >= gridN || gy >= gridN) return 0;
    return counts[gy * gridN + gx];
  };
  const above = (gx: number, gy: number): boolean => at(gx, gy) >= threshold;

  // One (interpolated) segment per 2x2 cell block that straddles the threshold.
  const segments: [Point, Point][] = [];
  for (let cy = -1; cy < gridN; cy++) {
    for (let cx = -1; cx < gridN; cx++) {
      const tl = above(cx, cy);
      const tr = above(cx + 1, cy);
      const bl = above(cx, cy + 1);
      const br = above(cx + 1, cy + 1);
      const caseIndex = (tl ? 8 : 0) | (tr ? 4 : 0) | (br ? 2 : 0) | (bl ? 1 : 0);
      if (caseIndex === 0 || caseIndex === 15) continue;

      const top: Point = { x: cx + 0.5, y: cy };
      const bottom: Point = { x: cx + 0.5, y: cy + 1 };
      const left: Point = { x: cx, y: cy + 0.5 };
      const right: Point = { x: cx + 1, y: cy + 0.5 };

      // Standard marching-squares edge table (ambiguous cases 5/10 resolved by
      // treating them as two separate diagonal segments, which is fine for our
      // purposes since we only need a boundary a point-in-polygon test can use).
      switch (caseIndex) {
        case 1:
        case 14:
          segments.push([left, bottom]);
          break;
        case 2:
        case 13:
          segments.push([bottom, right]);
          break;
        case 3:
        case 12:
          segments.push([left, right]);
          break;
        case 4:
        case 11:
          segments.push([top, right]);
          break;
        case 5:
          segments.push([left, top]);
          segments.push([bottom, right]);
          break;
        case 6:
        case 9:
          segments.push([top, bottom]);
          break;
        case 7:
        case 8:
          segments.push([left, top]);
          break;
        case 10:
          segments.push([top, right]);
          segments.push([left, bottom]);
          break;
        default:
          break;
      }
    }
  }

  return joinSegmentsIntoLoops(segments);
}

function keyOf(p: Point): string {
  return `${p.x.toFixed(3)},${p.y.toFixed(3)}`;
}

/** Walks marching-squares segments (which share endpoints where grid edges are shared) into closed polygon loops. */
function joinSegmentsIntoLoops(segments: [Point, Point][]): Point[][] {
  const adjacency = new Map<string, { point: Point; partners: Point[] }>();
  const addEndpoint = (p: Point, other: Point) => {
    const key = keyOf(p);
    const entry = adjacency.get(key) ?? { point: p, partners: [] };
    entry.partners.push(other);
    adjacency.set(key, entry);
  };
  for (const [a, b] of segments) {
    addEndpoint(a, b);
    addEndpoint(b, a);
  }

  const visited = new Set<string>();
  const loops: Point[][] = [];

  for (const [startKey, startEntry] of adjacency) {
    if (visited.has(startKey)) continue;
    const loop: Point[] = [startEntry.point];
    visited.add(startKey);
    let currentKey = startKey;
    let cameFrom: Point | null = null;
    // Follow the chain of segments until it returns to the start or runs out.
    for (let steps = 0; steps < segments.length + 1; steps++) {
      const entry = adjacency.get(currentKey);
      if (!entry) break;
      const next = entry.partners.find((p) => !cameFrom || keyOf(p) !== keyOf(cameFrom));
      if (!next) break;
      const nextKey = keyOf(next);
      if (nextKey === startKey) break;
      if (visited.has(nextKey)) break;
      loop.push(next);
      visited.add(nextKey);
      cameFrom = entry.point;
      currentKey = nextKey;
    }
    if (loop.length >= 3) loops.push(loop);
  }
  return loops;
}

/** Standard even-odd ray-casting point-in-polygon test (polygon in the same coordinate space as `point`). */
export function pointInPolygon(polygon: Point[], point: Point): boolean {
  let inside = false;
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const xi = polygon[i].x;
    const yi = polygon[i].y;
    const xj = polygon[j].x;
    const yj = polygon[j].y;
    const intersects = yi > point.y !== yj > point.y && point.x < ((xj - xi) * (point.y - yi)) / (yj - yi) + xi;
    if (intersects) inside = !inside;
  }
  return inside;
}

/** Picks whichever traced loop contains the given point (grid-space), if any. */
export function findLoopContainingPoint(loops: Point[][], point: Point): Point[] | null {
  for (const loop of loops) {
    if (pointInPolygon(loop, point)) return loop;
  }
  return null;
}
