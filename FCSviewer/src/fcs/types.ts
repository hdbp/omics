export interface FCSParameter {
  /** $PnN short name, e.g. "FSC-A" */
  name: string;
  /** $PnS stain/long name, e.g. "CD3-FITC" (falls back to name if absent) */
  label: string;
  /** $PnR instrument range */
  range: number;
}

export interface ParsedFCS {
  /** All TEXT segment keyword-value pairs, keys without the leading "$" stripped of case sensitivity issues preserved as-is */
  keywords: Record<string, string>;
  parameters: FCSParameter[];
  /** Column-major event data: data[paramIndex] is a Float32Array of length eventCount */
  data: Float32Array[];
  eventCount: number;
}
