import { makeId } from '../utils/id';
import { ROOT_GATE_ID, makeRootGate, type GateNode, type GateShape } from './gateTypes';

function shapeParams(shape: GateShape): string[] {
  return shape.kind === 'range' ? [shape.param] : [shape.xParam, shape.yParam];
}

export interface CloneResult {
  gates: Record<string, GateNode>;
  /** Names of gates (with their ancestor path) that were skipped because a required parameter was missing. */
  skipped: string[];
}

/**
 * Clones a gate hierarchy onto a different sample. Gate shapes reference raw
 * data values, so they carry over unchanged as long as the target sample has
 * the same parameter names; any gate (and its whole subtree) that depends on
 * a parameter the target doesn't have is skipped rather than applied broken.
 */
export function cloneGateTree(
  sourceGates: Record<string, GateNode>,
  targetParamIndex: Record<string, number>
): CloneResult {
  const gates: Record<string, GateNode> = { [ROOT_GATE_ID]: makeRootGate() };
  const idMap = new Map<string, string>([[ROOT_GATE_ID, ROOT_GATE_ID]]);
  const skipped: string[] = [];

  function visit(sourceId: string, pathPrefix: string) {
    const node = sourceGates[sourceId];
    if (!node) return;
    for (const childId of node.childIds) {
      const child = sourceGates[childId];
      if (!child || !child.shape) continue;
      const path = pathPrefix ? `${pathPrefix} > ${child.name}` : child.name;
      const missing = shapeParams(child.shape).some((p) => targetParamIndex[p] === undefined);
      if (missing) {
        skipped.push(path);
        continue; // skip this gate and everything under it
      }
      const newId = makeId('gate');
      const newParentId = idMap.get(sourceId) ?? ROOT_GATE_ID;
      idMap.set(childId, newId);
      gates[newId] = { id: newId, name: child.name, parentId: newParentId, shape: child.shape, childIds: [] };
      gates[newParentId] = { ...gates[newParentId], childIds: [...gates[newParentId].childIds, newId] };
      visit(childId, path);
    }
  }

  visit(ROOT_GATE_ID, '');
  return { gates, skipped };
}
