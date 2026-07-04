import type { FCSParameter } from '../fcs/types';
import type { GateNode } from '../gating/gateTypes';
import type { ColormapId } from '../utils/colormap';

/** Fractional (0-1) position of a draggable on-canvas annotation, relative to the plot area (not the whole panel). */
export interface AnnotationPos {
  xFrac: number;
  yFrac: number;
}

/** Which population-statistics fields a Layout panel's stats block should display. */
export type StatsFieldKey = 'population' | 'count' | 'percentParent' | 'percentTotal' | 'medianX' | 'medianY';

export const DEFAULT_STATS_FIELDS: StatsFieldKey[] = ['count', 'percentParent', 'percentTotal'];

export const STATS_FIELD_LABELS: Record<StatsFieldKey, string> = {
  population: 'Population path',
  count: 'Count',
  percentParent: '% of parent',
  percentTotal: '% of total',
  medianX: 'Median X',
  medianY: 'Median Y',
};

/**
 * A snapshot reference to another sample's population, drawn as an extra flat-colored
 * layer on top of a Layout panel's own plot (same axes) so two samples can be
 * contrasted on one plot. Captured by value (sampleId/gateId/label) rather than a
 * live link to the other Layout item, so it keeps working even if that item is later
 * removed or relabeled.
 */
export interface LayoutOverlayRef {
  id: string;
  sampleId: string;
  gateId: string;
  /** The other panel's label at the time it was added, shown in this panel's legend. */
  label: string;
  /** Flat color for this layer; auto-picked to differ from every other layer already in this panel's overlay. */
  color: string;
}

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
  /** Display text override for the X/Y axis (e.g. "GFP" instead of the raw "FL1-A" laser name). Unset means show the parameter's own name/stain. */
  xAxisLabel?: string;
  yAxisLabel?: string;
  /** Draggable position of the %parent/%total stats annotation drawn on the plot. Unset = default top-left placement. */
  statsAnnotation?: AnnotationPos;
  /** Pseudocolor density palette for dot plots. Unset = the default "jet"-style rainbow. */
  colormap?: ColormapId;
  /** Font family (CSS value) for all text drawn on this panel's canvas. Unset = system UI font. */
  fontFamily?: string;
  /** Base font size (px) for axis labels; ticks/quadrant/annotation text render 1px smaller. Unset = 11. */
  fontSize?: number;
  /** Position within the sample's workspace canvas, in px. */
  x: number;
  y: number;
  width: number;
  height: number;
}

/**
 * An item in the cross-sample "Layout" collage: a curated, independently
 * labeled/positioned copy of a panel's view (which sample, which population,
 * which axes) for assembling a publish-quality figure. Decoupled from the
 * source panel so moving/resizing/relabeling it here never touches the
 * sample's own analysis workspace, and removing the source panel doesn't
 * remove it from the layout.
 */
export interface LayoutItem {
  id: string;
  sampleId: string;
  gateId: string;
  /** Figure caption, independent of the gate's own name. */
  label: string;
  xParam: string;
  yParam: string;
  plotType: 'scatter' | 'histogram';
  xLogScale: boolean;
  yLogScale: boolean;
  xAxisLabel?: string;
  yAxisLabel?: string;
  /** Draggable position of the %parent/%total stats annotation drawn on the plot. Unset = default top-left placement. */
  statsAnnotation?: AnnotationPos;
  /** Which stats fields to print in the text block under this panel's plot. Unset = DEFAULT_STATS_FIELDS. */
  statsFields?: StatsFieldKey[];
  /** Pseudocolor density palette for dot plots. Unset = the default "jet"-style rainbow. */
  colormap?: ColormapId;
  /** Font family (CSS value) for all text drawn on this item's canvas. Unset = system UI font. */
  fontFamily?: string;
  /** Base font size (px) for axis labels; ticks/quadrant/annotation text render 1px smaller. Unset = 11. */
  fontSize?: number;
  /** Other samples' populations drawn on top of this panel's own plot (same axes), for contrasting samples. */
  overlays?: LayoutOverlayRef[];
  /** Flat color for this panel's own layer, assigned once it has its first overlay so its density heatmap doesn't visually clash with the overlays' flat colors. Unset (no overlays) keeps the normal density/colormap rendering. */
  overlayBaseColor?: string;
  x: number;
  y: number;
  width: number;
  height: number;
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
