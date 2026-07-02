import type { Sample } from '../state/types';
import { getColumn } from '../state/types';
import { getGateEventIndices } from './gateEval';
import { ROOT_GATE_ID } from './gateTypes';

export interface GateStat {
  gateId: string;
  name: string;
  depth: number;
  parentId: string | null;
  count: number;
  percentParent: number;
  percentTotal: number;
  indices: Uint32Array;
}

function median(col: Float32Array, indices: Uint32Array): number {
  if (indices.length === 0) return NaN;
  const vals = new Float32Array(indices.length);
  for (let i = 0; i < indices.length; i++) vals[i] = col[indices[i]];
  vals.sort();
  const mid = Math.floor(vals.length / 2);
  return vals.length % 2 === 0 ? (vals[mid - 1] + vals[mid]) / 2 : vals[mid];
}

/** Flattens the gate tree (depth-first) with per-node counts/percentages, relative to root and to each gate's parent. */
export function computeGateStats(sample: Sample): GateStat[] {
  const totalCount = sample.eventCount;
  const rootIndices = getGateEventIndices(sample, ROOT_GATE_ID);
  const countsById = new Map<string, Uint32Array>();
  countsById.set(ROOT_GATE_ID, rootIndices);

  const result: GateStat[] = [];

  function visit(gateId: string, depth: number) {
    const node = sample.gates[gateId];
    if (!node) return;
    const indices = countsById.get(gateId) ?? getGateEventIndices(sample, gateId);
    countsById.set(gateId, indices);
    const parentCount = node.parentId ? (countsById.get(node.parentId)?.length ?? totalCount) : totalCount;
    result.push({
      gateId,
      name: node.name,
      depth,
      parentId: node.parentId,
      count: indices.length,
      percentParent: parentCount > 0 ? (indices.length / parentCount) * 100 : 0,
      percentTotal: totalCount > 0 ? (indices.length / totalCount) * 100 : 0,
      indices,
    });
    for (const childId of node.childIds) {
      countsById.set(childId, getGateEventIndices(sample, childId));
      visit(childId, depth + 1);
    }
  }

  visit(ROOT_GATE_ID, 0);
  return result;
}

export function medianForParam(sample: Sample, indices: Uint32Array, paramName: string): number {
  return median(getColumn(sample, paramName), indices);
}
