import { create } from 'zustand';
import { parseFCS, FCSParseError } from '../fcs/parseFCS';
import { makeRootGate, ROOT_GATE_ID } from '../gating/gateTypes';
import type { GateShape, QuadrantId } from '../gating/gateTypes';
import { getDescendantIds } from '../gating/gateEval';
import { cloneGateTree } from '../gating/gateClone';
import { makeId } from '../utils/id';
import {
  nextPanelPosition,
  autoArrangeAll,
  nextLayoutPosition,
  autoArrangeLayoutGrid,
  DEFAULT_PANEL_WIDTH,
  DEFAULT_PANEL_HEIGHT,
  MIN_PANEL_WIDTH,
  MIN_PANEL_HEIGHT,
} from './panelLayout';
import type { Sample, Panel, LayoutItem, LayoutOverlayRef, StatsFieldKey } from './types';
import type { FCSParameter } from '../fcs/types';
import type { ColormapId } from '../utils/colormap';
import { pickOverlayColor } from '../utils/overlayColors';
import type { CellCycleAnalysis } from '../gating/cellCycle';

const QUADRANT_IDS: QuadrantId[] = ['UL', 'UR', 'LL', 'LR'];

function quadrantName(xParam: string, yParam: string, quadrant: QuadrantId): string {
  const xSign = quadrant === 'UR' || quadrant === 'LR' ? '+' : '-';
  const ySign = quadrant === 'UR' || quadrant === 'UL' ? '+' : '-';
  return `${xParam}${xSign} ${yParam}${ySign}`;
}

function pickDefaultAxes(parameters: FCSParameter[], avoid: string[]): [string, string] {
  const names = parameters.map((p) => p.name);
  const candidates = names.filter((n) => !avoid.includes(n));
  const x = candidates[0] ?? names[0] ?? '';
  const y = candidates[1] ?? candidates[0] ?? names[1] ?? names[0] ?? '';
  return [x, y];
}

/**
 * Clones a sample's panel layout onto another sample, remapping gate ids via
 * the map returned by cloneGateTree. A panel is dropped if its population
 * didn't survive cloning (missing parameter along its ancestry); a surviving
 * panel whose own axis choice references a parameter the target lacks falls
 * back to a default axis rather than referencing a nonexistent column.
 */
function clonePanels(
  sourcePanels: Panel[],
  gateIdMap: Map<string, string>,
  targetParamIndex: Record<string, number>,
  targetParameters: FCSParameter[]
): Panel[] {
  const panelIdMap = new Map<string, string>();
  const panels: Panel[] = [];
  for (const src of sourcePanels) {
    const newGateId = gateIdMap.get(src.gateId);
    if (!newGateId) continue;
    const newParentPanelId = src.parentPanelId ? (panelIdMap.get(src.parentPanelId) ?? null) : null;
    const xOk = targetParamIndex[src.xParam] !== undefined;
    const yOk = targetParamIndex[src.yParam] !== undefined;
    const [fallbackX, fallbackY] = pickDefaultAxes(targetParameters, []);
    const panel: Panel = {
      id: makeId('panel'),
      gateId: newGateId,
      parentPanelId: newParentPanelId,
      xParam: xOk ? src.xParam : fallbackX,
      yParam: yOk ? src.yParam : fallbackY,
      plotType: src.plotType,
      xLogScale: src.xLogScale,
      yLogScale: src.yLogScale,
      // A custom axis label only makes sense next to the parameter it was written for.
      xAxisLabel: xOk ? src.xAxisLabel : undefined,
      yAxisLabel: yOk ? src.yAxisLabel : undefined,
      statsAnnotation: src.statsAnnotation,
      colormap: src.colormap,
      fontFamily: src.fontFamily,
      fontSize: src.fontSize,
      x: src.x,
      y: src.y,
      width: src.width,
      height: src.height,
    };
    panelIdMap.set(src.id, panel.id);
    panels.push(panel);
  }
  return panels.length > 0 ? panels : [createRootPanel(targetParameters)];
}

function createRootPanel(parameters: FCSParameter[]): Panel {
  const [xParam, yParam] = pickDefaultAxes(parameters, []);
  return {
    id: makeId('panel'),
    gateId: ROOT_GATE_ID,
    parentPanelId: null,
    xParam,
    yParam,
    plotType: 'scatter',
    xLogScale: false,
    yLogScale: false,
    x: 24,
    y: 24,
    width: DEFAULT_PANEL_WIDTH,
    height: DEFAULT_PANEL_HEIGHT,
  };
}

interface AppState {
  samples: Sample[];
  activeSampleId: string | null;
  loading: boolean;
  error: string | null;
  notice: string | null;
  /** Panel to scroll into view / briefly highlight, set right after it's created or focused. */
  focusedPanelId: string | null;

  /** The cross-sample collage of curated panels, for assembling a publish-quality figure. */
  layoutItems: LayoutItem[];
  focusedLayoutItemId: string | null;
  /** Which main-content view is showing: the active sample's analysis workspace, the Layout collage, or the Notebook. */
  mainView: 'samples' | 'layout' | 'notebook';
  setMainView: (view: 'samples' | 'layout' | 'notebook') => void;

  /** Free-text notes about the assay/experiment, shared across the whole project. Saved with the project file. */
  notebookText: string;
  updateNotebookText: (text: string) => void;

  loadFiles: (files: FileList | File[]) => Promise<void>;
  removeSample: (sampleId: string) => void;
  selectSample: (sampleId: string) => void;
  clearError: () => void;
  clearNotice: () => void;

  updatePanelAxis: (sampleId: string, panelId: string, axis: 'xParam' | 'yParam', value: string) => void;
  updatePanelPlotType: (sampleId: string, panelId: string, plotType: 'scatter' | 'histogram') => void;
  updatePanelLogScale: (sampleId: string, panelId: string, axis: 'xLogScale' | 'yLogScale', value: boolean) => void;
  /** Display-text override for an axis (e.g. "GFP"); pass null to revert to the parameter's own name. */
  updatePanelAxisLabel: (sampleId: string, panelId: string, axis: 'xAxisLabel' | 'yAxisLabel', label: string | null) => void;
  /** Repositions the draggable %parent/%total stats annotation drawn on a panel's plot. */
  updatePanelStatsAnnotationPos: (sampleId: string, panelId: string, xFrac: number, yFrac: number) => void;
  /** Pseudocolor density palette for a panel's dot plot; pass null to revert to the default rainbow. */
  updatePanelColormap: (sampleId: string, panelId: string, colormap: ColormapId | null) => void;
  /** Font family/size for all text on a panel's canvas; pass null to revert to the default. */
  updatePanelFont: (sampleId: string, panelId: string, fontFamily: string | null, fontSize: number | null) => void;
  /** Sets/clears a panel's cell-cycle analysis (manual boundaries or an auto-fit result). Pass null to remove it. */
  updatePanelCellCycle: (sampleId: string, panelId: string, analysis: CellCycleAnalysis | null) => void;
  /** Creates the G1/S/G2M gates (adjacent range gates) from a panel's manual cell-cycle boundaries. */
  addCellCycleGates: (sampleId: string, parentId: string, xParam: string, xDomainMax: number, g1s: number, sg2m: number) => void;
  movePanel: (sampleId: string, panelId: string, x: number, y: number) => void;
  resizePanel: (sampleId: string, panelId: string, width: number, height: number) => void;
  removePanel: (sampleId: string, panelId: string) => void;
  autoArrangePanels: (sampleId: string) => void;
  /** Creates (or reuses) a child panel viewing `gateId`, drilled down from `parentPanelId`. Returns its id. */
  addChildPanel: (sampleId: string, parentPanelId: string | null, gateId: string) => string;
  /** Used from the gate tree: focuses an existing panel for this gate, or creates one anchored under the nearest ancestor panel. */
  focusPanelForGate: (sampleId: string, gateId: string) => void;
  focusPanel: (panelId: string | null) => void;

  addGate: (sampleId: string, parentId: string, name: string, shape: GateShape) => string;
  /** Creates the 4 quadrant child gates atomically (shared groupId, auto-named). */
  addQuadrantGates: (sampleId: string, parentId: string, xParam: string, yParam: string, x: number, y: number) => void;
  /** Live-updates the shared crosshair position for all 4 gates in a quadrant group. */
  updateQuadrantPosition: (sampleId: string, groupId: string, x: number, y: number) => void;
  renameGate: (sampleId: string, gateId: string, name: string) => void;
  setGateColor: (sampleId: string, gateId: string, color: string | null) => void;
  /** Reshapes/moves an existing rectangle/polygon/range gate. Any panel viewing it (or a descendant) recomputes live. */
  updateGateShape: (sampleId: string, gateId: string, shape: GateShape) => void;
  deleteGate: (sampleId: string, gateId: string) => void;

  applyGatingStrategy: (sourceSampleId: string, targetSampleIds: string[]) => void;

  /** Copies a panel's current view (population, axes, plot type, scale) into the Layout collage. Returns the new item id. */
  addToLayout: (sampleId: string, panelId: string) => string;
  updateLayoutItemAxis: (itemId: string, axis: 'xParam' | 'yParam', value: string) => void;
  updateLayoutItemPlotType: (itemId: string, plotType: 'scatter' | 'histogram') => void;
  updateLayoutItemAxisLabel: (itemId: string, axis: 'xAxisLabel' | 'yAxisLabel', label: string | null) => void;
  /** Repositions the draggable %parent/%total stats annotation drawn on a Layout item's plot. */
  updateLayoutItemStatsAnnotationPos: (itemId: string, xFrac: number, yFrac: number) => void;
  /** Which fields the stats block under a Layout item's plot should print. */
  updateLayoutItemStatsFields: (itemId: string, fields: StatsFieldKey[]) => void;
  /** Pseudocolor density palette for a Layout item's dot plot; pass null to revert to the default rainbow. */
  updateLayoutItemColormap: (itemId: string, colormap: ColormapId | null) => void;
  /** Font family/size for all text on a Layout item's canvas; pass null to revert to the default. */
  updateLayoutItemFont: (itemId: string, fontFamily: string | null, fontSize: number | null) => void;
  updateLayoutItemLogScale: (itemId: string, axis: 'xLogScale' | 'yLogScale', value: boolean) => void;
  relabelLayoutItem: (itemId: string, label: string) => void;
  moveLayoutItem: (itemId: string, x: number, y: number) => void;
  resizeLayoutItem: (itemId: string, width: number, height: number) => void;
  removeLayoutItem: (itemId: string) => void;
  autoArrangeLayout: () => void;
  focusLayoutItem: (itemId: string | null) => void;
  /** Draws another Layout item's population on top of this one (same axes), in its own flat color, for contrasting samples. No-op if already added. */
  addLayoutOverlay: (baseItemId: string, otherItemId: string) => void;
  removeLayoutOverlay: (baseItemId: string, overlayRefId: string) => void;
  clearLayoutOverlays: (baseItemId: string) => void;

  /** Wholesale-replaces the workspace with a project restored from a saved .fcsproj file. */
  loadProject: (project: {
    samples: Sample[];
    layoutItems: LayoutItem[];
    activeSampleId: string | null;
    mainView: 'samples' | 'layout' | 'notebook';
    notebookText: string;
  }) => void;
}

function updateSample(samples: Sample[], sampleId: string, fn: (s: Sample) => Sample): Sample[] {
  return samples.map((s) => (s.id === sampleId ? fn(s) : s));
}

export const useStore = create<AppState>((set, get) => ({
  samples: [],
  activeSampleId: null,
  loading: false,
  error: null,
  notice: null,
  focusedPanelId: null,
  layoutItems: [],
  focusedLayoutItemId: null,
  mainView: 'samples',
  notebookText: '',

  clearError: () => set({ error: null }),
  clearNotice: () => set({ notice: null }),
  focusPanel: (panelId) => set({ focusedPanelId: panelId }),
  setMainView: (view) => set({ mainView: view }),
  updateNotebookText: (text) => set({ notebookText: text }),

  loadFiles: async (fileList) => {
    const files = Array.from(fileList).filter((f) => f.name.toLowerCase().endsWith('.fcs'));
    if (files.length === 0) {
      set({ error: 'No .fcs files were selected.' });
      return;
    }
    set({ loading: true, error: null });

    const newSamples: Sample[] = [];
    const errors: string[] = [];
    for (const file of files) {
      try {
        const buffer = await file.arrayBuffer();
        const parsed = parseFCS(buffer);
        const paramIndex: Record<string, number> = {};
        parsed.parameters.forEach((p, i) => {
          paramIndex[p.name] = i;
        });
        const root = makeRootGate();
        newSamples.push({
          id: makeId('sample'),
          fileName: file.name,
          keywords: parsed.keywords,
          parameters: parsed.parameters,
          data: parsed.data,
          eventCount: parsed.eventCount,
          paramIndex,
          gates: { [ROOT_GATE_ID]: root },
          panels: [createRootPanel(parsed.parameters)],
        });
      } catch (e) {
        const msg = e instanceof FCSParseError ? e.message : `${e}`;
        errors.push(`${file.name}: ${msg}`);
      }
    }

    set((state) => ({
      samples: [...state.samples, ...newSamples],
      activeSampleId: state.activeSampleId ?? newSamples[0]?.id ?? null,
      loading: false,
      error: errors.length > 0 ? errors.join('\n') : null,
    }));
  },

  removeSample: (sampleId) =>
    set((state) => {
      const samples = state.samples.filter((s) => s.id !== sampleId);
      const activeSampleId =
        state.activeSampleId === sampleId ? (samples[0]?.id ?? null) : state.activeSampleId;
      const layoutItems = state.layoutItems.filter((it) => it.sampleId !== sampleId);
      return { samples, activeSampleId, layoutItems };
    }),

  selectSample: (sampleId) => set({ activeSampleId: sampleId, mainView: 'samples' }),

  updatePanelAxis: (sampleId, panelId, axis, value) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        panels: s.panels.map((p) => (p.id === panelId ? { ...p, [axis]: value } : p)),
      })),
    })),

  updatePanelPlotType: (sampleId, panelId, plotType) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        panels: s.panels.map((p) => (p.id === panelId ? { ...p, plotType } : p)),
      })),
    })),

  updatePanelLogScale: (sampleId, panelId, axis, value) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        panels: s.panels.map((p) => (p.id === panelId ? { ...p, [axis]: value } : p)),
      })),
    })),

  updatePanelAxisLabel: (sampleId, panelId, axis, label) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        panels: s.panels.map((p) => (p.id === panelId ? { ...p, [axis]: label ?? undefined } : p)),
      })),
    })),

  updatePanelStatsAnnotationPos: (sampleId, panelId, xFrac, yFrac) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        panels: s.panels.map((p) => (p.id === panelId ? { ...p, statsAnnotation: { xFrac, yFrac } } : p)),
      })),
    })),

  updatePanelColormap: (sampleId, panelId, colormap) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        panels: s.panels.map((p) => (p.id === panelId ? { ...p, colormap: colormap ?? undefined } : p)),
      })),
    })),

  updatePanelFont: (sampleId, panelId, fontFamily, fontSize) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        panels: s.panels.map((p) =>
          p.id === panelId ? { ...p, fontFamily: fontFamily ?? undefined, fontSize: fontSize ?? undefined } : p
        ),
      })),
    })),

  updatePanelCellCycle: (sampleId, panelId, analysis) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        panels: s.panels.map((p) => (p.id === panelId ? { ...p, cellCycle: analysis ?? undefined } : p)),
      })),
    })),

  addCellCycleGates: (sampleId, parentId, xParam, xDomainMax, g1s, sg2m) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => {
        const gates = { ...s.gates };
        const phases: [string, number, number][] = [
          ['G1', 0, g1s],
          ['S', g1s, sg2m],
          ['G2/M', sg2m, xDomainMax],
        ];
        const newIds: string[] = [];
        for (const [name, min, max] of phases) {
          const gateId = makeId('gate');
          gates[gateId] = { id: gateId, name, parentId, shape: { kind: 'range', param: xParam, min, max }, childIds: [] };
          newIds.push(gateId);
        }
        gates[parentId] = { ...gates[parentId], childIds: [...gates[parentId].childIds, ...newIds] };
        return { ...s, gates };
      }),
    })),

  movePanel: (sampleId, panelId, x, y) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        panels: s.panels.map((p) => (p.id === panelId ? { ...p, x, y } : p)),
      })),
    })),

  resizePanel: (sampleId, panelId, width, height) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        panels: s.panels.map((p) =>
          p.id === panelId
            ? { ...p, width: Math.max(MIN_PANEL_WIDTH, width), height: Math.max(MIN_PANEL_HEIGHT, height) }
            : p
        ),
      })),
    })),

  removePanel: (sampleId, panelId) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => {
        const removed = s.panels.find((p) => p.id === panelId);
        if (!removed) return s;
        const panels = s.panels
          .filter((p) => p.id !== panelId)
          .map((p) => (p.parentPanelId === panelId ? { ...p, parentPanelId: removed.parentPanelId } : p));
        return { ...s, panels };
      }),
    })),

  autoArrangePanels: (sampleId) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => {
        const positions = autoArrangeAll(s.panels);
        return { ...s, panels: s.panels.map((p) => ({ ...p, ...(positions.get(p.id) ?? {}) })) };
      }),
    })),

  addChildPanel: (sampleId, parentPanelId, gateId) => {
    let resultId = '';
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => {
        const existing = s.panels.find((p) => p.parentPanelId === parentPanelId && p.gateId === gateId);
        if (existing) {
          resultId = existing.id;
          return s;
        }
        const parent = parentPanelId ? (s.panels.find((p) => p.id === parentPanelId) ?? null) : null;
        const avoid = parent ? [parent.xParam, parent.yParam] : [];
        const [xParam, yParam] = pickDefaultAxes(s.parameters, avoid);
        const pos = nextPanelPosition(s.panels, parent);
        const panel: Panel = {
          id: makeId('panel'),
          gateId,
          parentPanelId,
          xParam,
          yParam,
          plotType: 'scatter',
          xLogScale: false,
          yLogScale: false,
          x: pos.x,
          y: pos.y,
          width: DEFAULT_PANEL_WIDTH,
          height: DEFAULT_PANEL_HEIGHT,
        };
        resultId = panel.id;
        return { ...s, panels: [...s.panels, panel] };
      }),
    }));
    set({ focusedPanelId: resultId });
    return resultId;
  },

  focusPanelForGate: (sampleId, gateId) => {
    const sample = get().samples.find((s) => s.id === sampleId);
    if (!sample) return;
    const existing = sample.panels.find((p) => p.gateId === gateId);
    if (existing) {
      set({ focusedPanelId: existing.id });
      return;
    }
    // Anchor the new panel under the nearest ancestor gate that already has a panel open.
    let parentPanel: Panel | null = null;
    let cur = sample.gates[gateId]?.parentId ? sample.gates[sample.gates[gateId].parentId!] : undefined;
    while (cur) {
      const p = sample.panels.find((pp) => pp.gateId === cur!.id);
      if (p) {
        parentPanel = p;
        break;
      }
      cur = cur.parentId ? sample.gates[cur.parentId] : undefined;
    }
    get().addChildPanel(sampleId, parentPanel?.id ?? null, gateId);
  },

  addGate: (sampleId, parentId, name, shape) => {
    const gateId = makeId('gate');
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => {
        const gates = { ...s.gates };
        gates[gateId] = { id: gateId, name, parentId, shape, childIds: [] };
        gates[parentId] = { ...gates[parentId], childIds: [...gates[parentId].childIds, gateId] };
        return { ...s, gates };
      }),
    }));
    return gateId;
  },

  addQuadrantGates: (sampleId, parentId, xParam, yParam, x, y) => {
    const groupId = makeId('quad');
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => {
        const gates = { ...s.gates };
        const newIds: string[] = [];
        for (const quadrant of QUADRANT_IDS) {
          const gateId = makeId('gate');
          gates[gateId] = {
            id: gateId,
            name: quadrantName(xParam, yParam, quadrant),
            parentId,
            shape: { kind: 'quadrant', xParam, yParam, x, y, quadrant, groupId },
            childIds: [],
          };
          newIds.push(gateId);
        }
        gates[parentId] = { ...gates[parentId], childIds: [...gates[parentId].childIds, ...newIds] };
        return { ...s, gates };
      }),
    }));
  },

  updateQuadrantPosition: (sampleId, groupId, x, y) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => {
        const gates = { ...s.gates };
        for (const [id, node] of Object.entries(gates)) {
          if (node.shape?.kind === 'quadrant' && node.shape.groupId === groupId) {
            gates[id] = { ...node, shape: { ...node.shape, x, y } };
          }
        }
        return { ...s, gates };
      }),
    })),

  renameGate: (sampleId, gateId, name) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        gates: { ...s.gates, [gateId]: { ...s.gates[gateId], name } },
      })),
    })),

  setGateColor: (sampleId, gateId, color) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        gates: { ...s.gates, [gateId]: { ...s.gates[gateId], color: color ?? undefined } },
      })),
    })),

  updateGateShape: (sampleId, gateId, shape) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        gates: { ...s.gates, [gateId]: { ...s.gates[gateId], shape } },
      })),
    })),

  deleteGate: (sampleId, gateId) => {
    if (gateId === ROOT_GATE_ID) return;
    const sample = get().samples.find((s) => s.id === sampleId);
    if (!sample) return;
    const toRemove = new Set([gateId, ...getDescendantIds(sample.gates, gateId)]);
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => {
        const gates: Sample['gates'] = {};
        for (const [id, node] of Object.entries(s.gates)) {
          if (toRemove.has(id)) continue;
          gates[id] = node;
        }
        const parentId = s.gates[gateId].parentId;
        if (parentId && gates[parentId]) {
          gates[parentId] = {
            ...gates[parentId],
            childIds: gates[parentId].childIds.filter((id) => id !== gateId),
          };
        }
        // Panels viewing a deleted gate can't survive; reparent their children panels upward so
        // the rest of the layout doesn't get orphaned.
        let panels = s.panels;
        for (const removedGateId of toRemove) {
          for (const doomed of panels.filter((p) => p.gateId === removedGateId)) {
            panels = panels
              .filter((p) => p.id !== doomed.id)
              .map((p) => (p.parentPanelId === doomed.id ? { ...p, parentPanelId: doomed.parentPanelId } : p));
          }
        }
        return { ...s, gates, panels };
      }),
      // Layout items are a curated copy, but one referencing a now-deleted population can't render.
      layoutItems: state.layoutItems.filter((it) => !(it.sampleId === sampleId && toRemove.has(it.gateId))),
    }));
  },

  applyGatingStrategy: (sourceSampleId, targetSampleIds) => {
    const source = get().samples.find((s) => s.id === sourceSampleId);
    if (!source) return;

    const targetNames = new Map(get().samples.map((s) => [s.id, s.fileName]));
    const noticeLines: string[] = [];

    set((state) => ({
      samples: state.samples.map((s) => {
        if (!targetSampleIds.includes(s.id)) return s;
        const { gates, skipped, idMap } = cloneGateTree(source.gates, s.paramIndex, s.gates);
        if (skipped.length > 0) {
          noticeLines.push(`${targetNames.get(s.id) ?? s.id}: skipped ${skipped.join(', ')} (parameter not found)`);
        }
        const panels = clonePanels(source.panels, idMap, s.paramIndex, s.parameters);
        return { ...s, gates, panels };
      }),
      // Old gate ids for each target sample no longer exist; drop any layout items built from them.
      layoutItems: state.layoutItems.filter((it) => !targetSampleIds.includes(it.sampleId)),
    }));

    const appliedCount = targetSampleIds.length;
    const summary = `Applied gating strategy and panel layout from "${source.fileName}" to ${appliedCount} sample${appliedCount === 1 ? '' : 's'}.`;
    set({ notice: noticeLines.length > 0 ? `${summary}\n${noticeLines.join('\n')}` : summary });
  },

  addToLayout: (sampleId, panelId) => {
    const sample = get().samples.find((s) => s.id === sampleId);
    const panel = sample?.panels.find((p) => p.id === panelId);
    let newId = '';
    if (!sample || !panel) return newId;
    const label = sample.gates[panel.gateId]?.name ?? 'Population';
    set((state) => {
      const pos = nextLayoutPosition(state.layoutItems);
      const item: LayoutItem = {
        id: makeId('layout'),
        sampleId,
        gateId: panel.gateId,
        label,
        xParam: panel.xParam,
        yParam: panel.yParam,
        plotType: panel.plotType,
        xLogScale: panel.xLogScale,
        yLogScale: panel.yLogScale,
        xAxisLabel: panel.xAxisLabel,
        yAxisLabel: panel.yAxisLabel,
        statsAnnotation: panel.statsAnnotation,
        colormap: panel.colormap,
        fontFamily: panel.fontFamily,
        fontSize: panel.fontSize,
        cellCycle: panel.cellCycle,
        x: pos.x,
        y: pos.y,
        width: panel.width,
        height: panel.height,
      };
      newId = item.id;
      return { layoutItems: [...state.layoutItems, item] };
    });
    set({ focusedLayoutItemId: newId, mainView: 'layout' });
    return newId;
  },

  updateLayoutItemAxis: (itemId, axis, value) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) => (it.id === itemId ? { ...it, [axis]: value } : it)),
    })),

  updateLayoutItemPlotType: (itemId, plotType) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) => (it.id === itemId ? { ...it, plotType } : it)),
    })),

  updateLayoutItemAxisLabel: (itemId, axis, label) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) => (it.id === itemId ? { ...it, [axis]: label ?? undefined } : it)),
    })),

  updateLayoutItemStatsAnnotationPos: (itemId, xFrac, yFrac) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) => (it.id === itemId ? { ...it, statsAnnotation: { xFrac, yFrac } } : it)),
    })),

  updateLayoutItemStatsFields: (itemId, fields) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) => (it.id === itemId ? { ...it, statsFields: fields } : it)),
    })),

  updateLayoutItemColormap: (itemId, colormap) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) => (it.id === itemId ? { ...it, colormap: colormap ?? undefined } : it)),
    })),

  updateLayoutItemFont: (itemId, fontFamily, fontSize) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) =>
        it.id === itemId ? { ...it, fontFamily: fontFamily ?? undefined, fontSize: fontSize ?? undefined } : it
      ),
    })),

  updateLayoutItemLogScale: (itemId, axis, value) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) => (it.id === itemId ? { ...it, [axis]: value } : it)),
    })),

  relabelLayoutItem: (itemId, label) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) => (it.id === itemId ? { ...it, label } : it)),
    })),

  moveLayoutItem: (itemId, x, y) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) => (it.id === itemId ? { ...it, x, y } : it)),
    })),

  resizeLayoutItem: (itemId, width, height) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) =>
        it.id === itemId ? { ...it, width: Math.max(MIN_PANEL_WIDTH, width), height: Math.max(MIN_PANEL_HEIGHT, height) } : it
      ),
    })),

  removeLayoutItem: (itemId) =>
    set((state) => ({ layoutItems: state.layoutItems.filter((it) => it.id !== itemId) })),

  autoArrangeLayout: () =>
    set((state) => {
      const positions = autoArrangeLayoutGrid(state.layoutItems);
      return { layoutItems: state.layoutItems.map((it) => ({ ...it, ...(positions.get(it.id) ?? {}) })) };
    }),

  focusLayoutItem: (itemId) => set({ focusedLayoutItemId: itemId }),

  addLayoutOverlay: (baseItemId, otherItemId) =>
    set((state) => {
      const other = state.layoutItems.find((it) => it.id === otherItemId);
      if (!other) return state;
      return {
        layoutItems: state.layoutItems.map((it) => {
          if (it.id !== baseItemId) return it;
          const overlays = it.overlays ?? [];
          const alreadyAdded = overlays.some((o) => o.sampleId === other.sampleId && o.gateId === other.gateId);
          if (alreadyAdded) return it;
          const baseColor = it.overlayBaseColor ?? pickOverlayColor(overlays.map((o) => o.color));
          const newRef: LayoutOverlayRef = {
            id: makeId('overlay'),
            sampleId: other.sampleId,
            gateId: other.gateId,
            label: other.label,
            color: pickOverlayColor([baseColor, ...overlays.map((o) => o.color)]),
          };
          return { ...it, overlayBaseColor: baseColor, overlays: [...overlays, newRef] };
        }),
      };
    }),

  removeLayoutOverlay: (baseItemId, overlayRefId) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) => {
        if (it.id !== baseItemId) return it;
        const overlays = (it.overlays ?? []).filter((o) => o.id !== overlayRefId);
        return overlays.length > 0 ? { ...it, overlays } : { ...it, overlays: undefined, overlayBaseColor: undefined };
      }),
    })),

  clearLayoutOverlays: (baseItemId) =>
    set((state) => ({
      layoutItems: state.layoutItems.map((it) =>
        it.id === baseItemId ? { ...it, overlays: undefined, overlayBaseColor: undefined } : it
      ),
    })),

  loadProject: ({ samples, layoutItems, activeSampleId, mainView, notebookText }) =>
    set({
      samples,
      layoutItems,
      activeSampleId,
      mainView,
      notebookText,
      focusedPanelId: null,
      focusedLayoutItemId: null,
      loading: false,
      error: null,
      notice: null,
    }),
}));

export function getActiveSample(state: AppState): Sample | null {
  return state.samples.find((s) => s.id === state.activeSampleId) ?? null;
}
