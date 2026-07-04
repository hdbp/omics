import { makeId } from '../utils/id';
import { ROOT_GATE_ID, makeRootGate, type GateNode, type GateShape } from './gateTypes';

function shapeParams(shape: GateShape): string[] {
  return shape.kind === 'range' ? [shape.param] : [shape.xParam, shape.yParam];
}

export interface CloneResult {
  gates: Record<string, GateNode>;
  /** Names of gates (with their ancestor path) that were skipped because a required parameter was missing. */
  skipped: string[];
  /** Old gate id -> new gate id, for remapping anything else (e.g. panels) that references gate ids. */
  idMap: Map<string, string>;
}

/**
 * Clones a gate hierarchy onto a different sample. Gate shapes reference raw
 * data values, so they carry over unchanged as long as the target sample has
 * the same parameter names; any gate (and its whole subtree) that depends on
 * a parameter the target doesn't have is skipped rather than applied broken.
 *
 * If the target already has its own gates (`existingTargetGates`), each new
 * gate keeps the *name* of whatever gate previously sat in the same position
 * in the target's tree (same parent, same child index) instead of adopting
 * the source's name — only the shape/boundary and panel layout are meant to
 * transfer, not naming the target sample already chose for its own
 * populations. A target gate position with nothing there yet (or a target
 * with no prior gates at all) just falls back to the source's name.
 */
export function cloneGateTree(
  sourceGates: Record<string, GateNode>,
  targetParamIndex: Record<string, number>,
  existingTargetGates?: Record<string, GateNode>
): CloneResult {
  const gates: Record<string, GateNode> = { [ROOT_GATE_ID]: makeRootGate() };
  const idMap = new Map<string, string>([[ROOT_GATE_ID, ROOT_GATE_ID]]);
  const skipped: string[] = [];

  function visit(sourceId: string, existingId: string | undefined, pathPrefix: string) {
    const node = sourceGates[sourceId];
    if (!node) return;
    const existingNode = existingId ? existingTargetGates?.[existingId] : undefined;
    node.childIds.forEach((childId, index) => {
      const child = sourceGates[childId];
      if (!child || !child.shape) return;
      const path = pathPrefix ? `${pathPrefix} > ${child.name}` : child.name;
      const missing = shapeParams(child.shape).some((p) => targetParamIndex[p] === undefined);
      if (missing) {
        skipped.push(path);
        return; // skip this gate and everything under it
      }
      const existingChildId = existingNode?.childIds[index];
      const existingChild = existingChildId ? existingTargetGates?.[existingChildId] : undefined;
      const newId = makeId('gate');
      const newParentId = idMap.get(sourceId) ?? ROOT_GATE_ID;
      idMap.set(childId, newId);
      gates[newId] = {
        id: newId,
        name: existingChild?.name ?? child.name,
        parentId: newParentId,
        shape: child.shape,
        childIds: [],
        color: child.color,
      };
      gates[newParentId] = { ...gates[newParentId], childIds: [...gates[newParentId].childIds, newId] };
      visit(childId, existingChildId, path);
    });
  }

  visit(ROOT_GATE_ID, ROOT_GATE_ID, '');
  return { gates, skipped, idMap };
}
