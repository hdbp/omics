import { create } from 'zustand';
import { parseFCS, FCSParseError } from '../fcs/parseFCS';
import { makeRootGate, ROOT_GATE_ID } from '../gating/gateTypes';
import type { GateShape } from '../gating/gateTypes';
import { getDescendantIds } from '../gating/gateEval';
import type { Sample } from './types';

let nextId = 1;
function makeId(prefix: string): string {
  return `${prefix}-${nextId++}-${Date.now().toString(36)}`;
}

interface AppState {
  samples: Sample[];
  activeSampleId: string | null;
  loading: boolean;
  error: string | null;

  loadFiles: (files: FileList | File[]) => Promise<void>;
  removeSample: (sampleId: string) => void;
  selectSample: (sampleId: string) => void;
  clearError: () => void;

  setAxis: (sampleId: string, axis: 'xParam' | 'yParam', value: string) => void;
  setPlotType: (sampleId: string, plotType: 'scatter' | 'histogram') => void;
  selectGate: (sampleId: string, gateId: string) => void;

  addGate: (sampleId: string, parentId: string, name: string, shape: GateShape) => string;
  renameGate: (sampleId: string, gateId: string, name: string) => void;
  deleteGate: (sampleId: string, gateId: string) => void;
}

function updateSample(samples: Sample[], sampleId: string, fn: (s: Sample) => Sample): Sample[] {
  return samples.map((s) => (s.id === sampleId ? fn(s) : s));
}

export const useStore = create<AppState>((set) => ({
  samples: [],
  activeSampleId: null,
  loading: false,
  error: null,

  clearError: () => set({ error: null }),

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
        const xParam = parsed.parameters[0]?.name ?? '';
        const yParam = parsed.parameters[1]?.name ?? parsed.parameters[0]?.name ?? '';
        newSamples.push({
          id: makeId('sample'),
          fileName: file.name,
          keywords: parsed.keywords,
          parameters: parsed.parameters,
          data: parsed.data,
          eventCount: parsed.eventCount,
          paramIndex,
          gates: { [ROOT_GATE_ID]: root },
          activeGateId: ROOT_GATE_ID,
          xParam,
          yParam,
          plotType: 'scatter',
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

  setAxis: (sampleId, axis, value) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({ ...s, [axis]: value })),
    })),

  setPlotType: (sampleId, plotType) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({ ...s, plotType })),
    })),

  selectGate: (sampleId, gateId) =>
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => ({ ...s, activeGateId: gateId })),
    })),

  addGate: (sampleId, parentId, name, shape) => {
    const gateId = makeId('gate');
    set((state) => ({
      samples: updateSample(state.samples, sampleId, (s) => {
        const gates = { ...s.gates };
        gates[gateId] = { id: gateId, name, parentId, shape, childIds: [] };
        gates[parentId] = { ...gates[parentId], childIds: [...gates[parentId].childIds, gateId] };
        return { ...s, gates, activeGateId: gateId };
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
        const activeGateId = toRemove.has(s.activeGateId) ? (parentId ?? ROOT_GATE_ID) : s.activeGateId;
        return { ...s, gates, activeGateId };
      }),
    }));
  },
}));

export function getActiveSample(state: AppState): Sample | null {
  return state.samples.find((s) => s.id === state.activeSampleId) ?? null;
}
