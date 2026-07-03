import type { Sample, StatsFieldKey } from '../state/types';
import { getColumn } from '../state/types';
import { getGateEventIndices, ancestorChain } from './gateEval';
import { ROOT_GATE_ID } from './gateTypes';
import type { GateNode, QuadrantId } from './gateTypes';

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

/** %-of-parent and %-of-total for a single gate's already-computed event indices (root gates report 100% of parent). */
export function gatePercentages(
  sample: Sample,
  gateNode: GateNode | undefined,
  indices: Uint32Array
): { percentParent: number; percentTotal: number } {
  const percentTotal = sample.eventCount > 0 ? (indices.length / sample.eventCount) * 100 : 0;
  if (!gateNode?.parentId) return { percentParent: 100, percentTotal };
  const parentIndices = getGateEventIndices(sample, gateNode.parentId);
  const percentParent = parentIndices.length > 0 ? (indices.length / parentIndices.length) * 100 : 0;
  return { percentParent, percentTotal };
}

export interface LayoutItemStats {
  populationPath: string;
  count: number;
  percentParent: number;
  percentTotal: number;
  medianX: number;
  medianY: number;
}

/** All the raw numbers a Layout panel's stats block (or its PNG-export equivalent) might print, for one population/axis pair. */
export function computeLayoutItemStats(
  sample: Sample,
  gateId: string,
  xParam: string,
  yParam: string,
  plotType: 'scatter' | 'histogram'
): LayoutItemStats {
  const gateNode = sample.gates[gateId];
  const indices = getGateEventIndices(sample, gateId);
  const { percentParent, percentTotal } = gatePercentages(sample, gateNode, indices);
  return {
    populationPath: ancestorChain(sample.gates, gateId)
      .map((n) => n.name)
      .join(' › '),
    count: indices.length,
    percentParent,
    percentTotal,
    medianX: medianForParam(sample, indices, xParam),
    medianY: plotType === 'scatter' ? medianForParam(sample, indices, yParam) : NaN,
  };
}

export interface QuadrantStat {
  count: number;
  percentParent: number;
  percentTotal: number;
}

export interface QuadrantGroupInfo {
  x: number;
  y: number;
  labels: Partial<Record<QuadrantId, string>>;
  colors: Partial<Record<QuadrantId, string>>;
  stats: Partial<Record<QuadrantId, QuadrantStat>>;
}

/**
 * Groups a gate's quadrant-shaped children by crosshair placement (groupId), with each
 * quadrant's name/color plus its own count/%parent/%total — shared by the live panel
 * canvases (GatePanel, LayoutPanel) and the PNG export renderer so quadrant stats always
 * match the statistics table.
 */
export function collectQuadrantGroups(
  sample: Sample,
  gateNode: GateNode | undefined,
  xParam: string,
  yParam: string
): Map<string, QuadrantGroupInfo> {
  const groups = new Map<string, QuadrantGroupInfo>();
  for (const childId of gateNode?.childIds ?? []) {
    const child = sample.gates[childId];
    const shape = child?.shape;
    if (shape?.kind !== 'quadrant' || shape.xParam !== xParam || shape.yParam !== yParam) continue;
    const group = groups.get(shape.groupId) ?? { x: shape.x, y: shape.y, labels: {}, colors: {}, stats: {} };
    group.labels[shape.quadrant] = child.name;
    if (child.color) group.colors[shape.quadrant] = child.color;
    const indices = getGateEventIndices(sample, childId);
    const { percentParent, percentTotal } = gatePercentages(sample, child, indices);
    group.stats[shape.quadrant] = { count: indices.length, percentParent, percentTotal };
    groups.set(shape.groupId, group);
  }
  return groups;
}

/** Renders one stats field as display text, matching the live Layout panel and the exported PNG/CSV. */
export function formatStatsField(key: StatsFieldKey, stats: LayoutItemStats, plotType: 'scatter' | 'histogram'): string {
  switch (key) {
    case 'population':
      return stats.populationPath;
    case 'count':
      return stats.count.toLocaleString();
    case 'percentParent':
      return `${stats.percentParent.toFixed(1)}%`;
    case 'percentTotal':
      return `${stats.percentTotal.toFixed(1)}%`;
    case 'medianX':
      return Number.isFinite(stats.medianX) ? stats.medianX.toFixed(1) : '—';
    case 'medianY':
      return plotType === 'scatter' && Number.isFinite(stats.medianY) ? stats.medianY.toFixed(1) : '—';
  }
}
