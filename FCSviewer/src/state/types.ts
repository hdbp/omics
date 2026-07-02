import type { FCSParameter } from '../fcs/types';
import type { GateNode } from '../gating/gateTypes';

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
  /** Currently selected population being viewed / gated on. */
  activeGateId: string;
  xParam: string;
  yParam: string;
  plotType: 'scatter' | 'histogram';
  xLogScale: boolean;
  yLogScale: boolean;
}

export function getColumn(sample: Sample, paramName: string): Float32Array {
  const idx = sample.paramIndex[paramName];
  if (idx === undefined) {
    throw new Error(`Sample "${sample.fileName}" has no parameter named "${paramName}".`);
  }
  return sample.data[idx];
}
