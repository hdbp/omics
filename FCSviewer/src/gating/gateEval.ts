import type { Sample } from '../state/types';
import { getColumn } from '../state/types';
import type { GateNode, GateShape } from './gateTypes';

function pointInPolygon(x: number, y: number, points: { x: number; y: number }[]): boolean {
  let inside = false;
  for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
    const xi = points[i].x;
    const yi = points[i].y;
    const xj = points[j].x;
    const yj = points[j].y;
    const intersects = yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi;
    if (intersects) inside = !inside;
  }
  return inside;
}

function testShape(shape: GateShape, xVal: number, yVal: number): boolean {
  switch (shape.kind) {
    case 'rectangle': {
      const xMin = Math.min(shape.x1, shape.x2);
      const xMax = Math.max(shape.x1, shape.x2);
      const yMin = Math.min(shape.y1, shape.y2);
      const yMax = Math.max(shape.y1, shape.y2);
      return xVal >= xMin && xVal <= xMax && yVal >= yMin && yVal <= yMax;
    }
    case 'polygon':
      return pointInPolygon(xVal, yVal, shape.points);
    case 'range':
      return xVal >= Math.min(shape.min, shape.max) && xVal <= Math.max(shape.min, shape.max);
  }
}

function ancestorChain(gates: Record<string, GateNode>, gateId: string): GateNode[] {
  const chain: GateNode[] = [];
  let cur: GateNode | undefined = gates[gateId];
  while (cur) {
    chain.unshift(cur);
    cur = cur.parentId ? gates[cur.parentId] : undefined;
  }
  return chain;
}

/** Returns the indices of events in `sample` that pass every gate from root down to `gateId`. */
export function getGateEventIndices(sample: Sample, gateId: string): Uint32Array {
  const chain = ancestorChain(sample.gates, gateId);
  let candidates: Uint32Array = Uint32Array.from({ length: sample.eventCount }, (_, i) => i);

  for (const node of chain) {
    if (!node.shape) continue; // root: no filtering
    const shape = node.shape;
    const xCol = getColumn(sample, shape.kind === 'range' ? shape.param : shape.xParam);
    const yCol = shape.kind === 'range' ? null : getColumn(sample, shape.yParam);
    const next: number[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const idx = candidates[i];
      const xv = xCol[idx];
      const yv = yCol ? yCol[idx] : 0;
      if (testShape(shape, xv, yv)) next.push(idx);
    }
    candidates = Uint32Array.from(next);
  }
  return candidates;
}

export function getDescendantIds(gates: Record<string, GateNode>, gateId: string): string[] {
  const result: string[] = [];
  const stack = [...(gates[gateId]?.childIds ?? [])];
  while (stack.length) {
    const id = stack.pop()!;
    result.push(id);
    stack.push(...(gates[id]?.childIds ?? []));
  }
  return result;
}
