import type { FCSParameter } from '../fcs/types';
import type { GateNode } from '../gating/gateTypes';

/**
 * A single plot in a sample's workspace. Each panel is permanently bound to
 * one population (gateId) with its own axes/scale/plot type — mirroring
 * FlowJo's layout of linked plots rather than one plot that swaps in place.
 * Drilling into a gate creates a new child panel instead of navigating.
 */
export interface Panel {
  id: string;
  gateId: string;
  /** The panel this one was drilled down from, for layout + connector lines. Null for a root-level panel. */
  parentPanelId: string | null;
  xParam: string;
  yParam: string;
  plotType: 'scatter' | 'histogram';
  xLogScale: boolean;
  yLogScale: boolean;
  /** Position within the sample's workspace canvas, in px. */
  x: number;
  y: number;
}

export interface Sample {
  id: string;
  fileName: string;
  keywords: Record<string, string>;
  parameters: FCSParameter[];
  /** Column-major event data; data[i] corresponds to parameters[i]. */
  data: Float32Array[];
  eventCount: number;
  /** parameter short name ($PnN) -> column index, for O(1) lookup */
  paramIndex: Record<string, number>;
  /** All gates for this sample, keyed by id, including the synthetic root. */
  gates: Record<string, GateNode>;
  /** All open plots for this sample. */
  panels: Panel[];
}

export function getColumn(sample: Sample, paramName: string): Float32Array {
  const idx = sample.paramIndex[paramName];
  if (idx === undefined) {
    throw new Error(`Sample "${sample.fileName}" has no parameter named "${paramName}".`);
  }
  return sample.data[idx];
}
