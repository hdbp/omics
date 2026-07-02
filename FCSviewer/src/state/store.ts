import { create } from 'zustand';
import { parseFCS, FCSParseError } from '../fcs/parseFCS';
import { makeRootGate, ROOT_GATE_ID } from '../gating/gateTypes';
import type { GateShape } from '../gating/gateTypes';
import { getDescendantIds } from '../gating/gateEval';
import { cloneGateTree } from '../gating/gateClone';
import { makeId } from '../utils/id';
import { nextPanelPosition, autoArrangeAll } from './panelLayout';
import type { Sample, Panel } from './types';
import type { FCSParameter } from '../fcs/types';

function pickDefaultAxes(parameters: FCSParameter[], avoid: string[]): [string, string] {
  const names = parameters.map((p) => p.name);
  const candidates = names.filter((n) => !avoid.includes(n));
  const x = candidates[0] ?? names[0] ?? '';
  const y = candidates[1] ?? candidates[0] ?? names[1] ?? names[0] ?? '';
  return [x, y];
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

  loadFiles: (files: FileList | File[]) => Promise<void>;
  removeSample: (sampleId: string) => void;
  selectSample: (sampleId: string) => void;
  clearError: () => void;
  clearNotice: () => void;

  updatePanelAxis: (sampleId: string, panelId: string, axis: 'xParam' | 'yParam', value: string) => void;
  updatePanelPlotType: (sampleId: string, panelId: string, plotType: 'scatter' | 'histogram') => void;
  updatePanelLogScale: (sampleId: string, panelId: string, axis: 'xLogScale' | 'yLogScale', value: boolean) => void;
  movePanel: (sampleId: string, panelId: string, x: number, y: number) => void;
  removePanel: (sampleId: string, panelId: string) => void;
  autoArrangePanels: (sampleId: string) => void;
  /** Creates (or reuses) a child panel viewing `gateId`, drilled down from `parentPanelId`. Returns its id. */
  addChildPanel: (sampleId: string, parentPanelId: string | null, gateId: string) => string;
  /** Used from the gate tree: focuses an existing panel for this gate, or creates one anchored under the nearest ancestor panel. */
  focusPanelForGate: (sampleId: string, gateId: string) => void;
  focusPanel: (panelId: string | null) => void;

  addGate: (sampleId: string, parentId: string, name: string, shape: GateShape) => string;
  renameGate: (sampleId: string, gateId: string, name: string) => void;
  deleteGate: (sampleId: string, gateId: string) => void;

  applyGatingStrategy: (sourceSampleId: string, targetSampleIds: string[]) => void;
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

  clearError: () => set({ error: null }),
  clearNotice: () => set({ notice: null }),
  focusPanel: (panelId) => set({ focusedPanelId: panelId }),

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
      return { samples, activeSampleId };
    }),

  selectSample: (sampleId) => set({ activeSampleId: sampleId }),

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

  movePanel: (sampleId, panelId, x, y) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        panels: s.panels.map((p) => (p.id === panelId ? { ...p, x, y } : p)),
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

  renameGate: (sampleId, gateId, name) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({
        ...s,
        gates: { ...s.gates, [gateId]: { ...s.gates[gateId], name } },
      })),
    })),

  deleteGate: (sampleId, gateId) => {
    if (gateId === ROOT_GATE_ID) return;
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => {
        const toRemove = new Set([gateId, ...getDescendantIds(s.gates, gateId)]);
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
        const { gates, skipped } = cloneGateTree(source.gates, s.paramIndex);
        if (skipped.length > 0) {
          noticeLines.push(`${targetNames.get(s.id) ?? s.id}: skipped ${skipped.join(', ')} (parameter not found)`);
        }
        // Old panels reference gate ids from the previous tree, which no longer exist; start fresh.
        return { ...s, gates, panels: [createRootPanel(s.parameters)] };
      }),
    }));

    const appliedCount = targetSampleIds.length;
    const summary = `Applied gating strategy from "${source.fileName}" to ${appliedCount} sample${appliedCount === 1 ? '' : 's'}.`;
    set({ notice: noticeLines.length > 0 ? `${summary}\n${noticeLines.join('\n')}` : summary });
  },
}));

export function getActiveSample(state: AppState): Sample | null {
  return state.samples.find((s) => s.id === state.activeSampleId) ?? null;
}
