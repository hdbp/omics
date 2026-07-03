# FCS Viewer

A lightweight, standalone, in-browser viewer for flow cytometry `.fcs` files that mimics FlowJo's core workflow: load data, build a layout of linked plots by drilling into gates, and view live statistics. It's a static React/TypeScript single-page app — there is no backend, and files never leave the browser.

## Features

- **Load `.fcs` files** — drag-and-drop or file picker, multiple samples at once. Supports FCS 3.0/3.1 list-mode files with `INT`/`FLOAT`/`DOUBLE` data types and byte-aligned parameter widths (8/16/32/64-bit).
- **A workspace of linked plots, not one plot that swaps in place** — like FlowJo, each sample gets a canvas of "panels." Every panel is a dot plot or histogram bound permanently to one population, with its own X/Y axes, log/linear scale, and plot type.
- **Gate, then drill down into a brand-new panel** — draw a rectangle/polygon gate on a panel (e.g. FSC-A vs SSC-A), then click the gated region to open it in a *new* panel, connected to its parent by a line. Pick different axes there (e.g. GFP vs BFP) and gate again — each drill-down spawns another linked panel, building out the full gating tree visually.
- **Gates stay editable after you've drilled into them** — every rectangle/polygon/range gate shows small drag handles on the panel you drew it on. Drag a handle to reshape it, or drag its body to move it; any panel already drilled into that population (or a descendant of it) recomputes its events and stats live, no need to redraw or re-drill.
- **Resize, rearrange, and export the layout** — drag any panel by its header to reposition it, drag its bottom-right corner to resize it, click **Auto-arrange** to snap everything back to a clean tree layout (respecting each panel's current size), and **Export layout as PNG** to save the whole assembled panel-and-connector diagram as one image.
- **Label panels and color populations** — double-click a panel's title to rename its population (shared with the gate tree). Click the small color swatch in a panel's header or next to a gate in the tree to assign it a color: child-gate outlines/quadrant labels are drawn in their assigned color, and a panel showing a colored population renders its own events in that flat color instead of the default density heatmap.
- **Quadrant gates** — click-drag to place a crosshair on a dot plot, splitting it into 4 populations (auto-named by +/- for each axis) with a single gesture. Drag the crosshair intersection afterward to reposition all 4 at once — every quadrant is a regular gate, so it gets its own row (count, %parent, %total, median) in the statistics table and can itself be drilled into.
- **Log axis scale** — toggle **log X** / **log Y** per panel independently (log10, floored at 1) — useful for fluorescence channels that are hard to read on a linear scale.
- **Apply a gating strategy to other samples** — clone the active sample's entire gate hierarchy *and panel layout* onto other loaded samples in one step: the same chain of linked panels (axes, plot type, log scale, position) is recreated on each target, recomputed against its own data. Gates/panels that depend on a parameter missing from a target sample are skipped (with a summary of what was skipped), rather than applied broken.
- **Statistics table** — count, % of parent, % of total, and median (for two parameters you choose) for every gate across the whole sample, live-updating as you gate. Export the table, or any single population's raw events, as CSV.
- **A dedicated Layout collage for publication figures** — a separate "Layout" section in the sidebar, independent of any one sample's analysis workspace. Click **⊞** in any panel's header (in any sample) to add a curated copy of it — its own axes, plot type, and a free-text caption — to the Layout. Mix panels from different samples, drag/resize/relabel them, click **Auto-arrange** for a clean grid, and **Export layout as PNG** to save the whole collage as one publish-quality image.
- **Custom axis labels** — type into the small text box next to a panel's X/Y parameter dropdown (in either a sample's workspace or the Layout) to override what's printed on the plot axis, e.g. swap a laser/detector name like `FL1-A` for `GFP`. Leave it blank to fall back to the parameter name. Carries over automatically when a panel is added to the Layout.
- **Layout alignment helpers** — click a panel's header in the Layout to select it, shift-click to add more to the selection; a toolbar appears to align the selection's edges or centers (**Left/Right/Top/Bottom/Ctr X/Ctr Y**) or **Dist X/Dist Y** to space 3+ selected panels evenly. Dragging any panel also snaps to nearby panels' edges/centers (within a few pixels) and shows a dashed guide line while it's snapped. Click empty canvas space to clear the selection.
- **Layout population statistics export** — **Export stats CSV** in the Layout toolbar writes one row per panel in the collage: sample, population path, event count, % of parent, % of total, and median of each axis parameter (using its custom label if set) — everything you need to caption a figure with real numbers.

Not included in this version: compensation/spillover matrices and full biexponential/logicle transforms — the log option is a straight log10 (floored at 1), not FlowJo's logicle.

## Running it

```bash
cd FCSviewer
npm install
npm run dev
```

Then open the printed local URL. To produce a static production build (deployable to any static file host, e.g. GitHub Pages or S3):

```bash
npm run build   # outputs to dist/
npm run preview # serve the production build locally
```

## Usage

1. Drop one or more `.fcs` files onto the panel on the left (or click it to browse). Each sample opens with one root panel showing all events.
2. In a panel, pick X/Y parameters from its dropdowns, switch between **Dot plot** and **Histogram**, and toggle **log X**/**log Y** as needed.
3. Click the **▭** (rectangle), **⬠** (polygon), **✛** (quadrant), or **↔** (range, histogram only) button, then draw on that panel's plot:
   - Rectangle/range: click-drag.
   - Polygon: click to add each vertex, then click near the first vertex, double-click, or press <kbd>Enter</kbd> to close it. <kbd>Esc</kbd> cancels.
   - Quadrant (dot plots only): click-drag to place the crosshair, release to instantly create all 4 quadrant gates (auto-named, no dialog). Afterward, drag the crosshair intersection again (with no tool active) to reposition all 4 together — stats update live.
4. For rectangle/polygon/range gates, name the gate when prompted; its outline appears on the panel you drew it on, with small handles at its corners/vertices/edges.
5. **Click inside a gated region** (with no drawing tool active) to drill down — this opens a *new panel* for that population, connected to the one you drew from, with fresh default axes so you can immediately pick different channels (e.g. GFP/BFP). Works for quadrant regions too. Repeat to build out the full gating tree as a chain of linked panels.
6. **Go back and adjust a gate any time** — on the panel where you drew it, drag one of its handles to reshape it, or drag its body (away from a handle) to move it. A plain click still drills down; only an actual drag reshapes/moves. Any panel already drilled into that gate (or a descendant of it) updates its population and stats immediately.
7. Drag a panel by its header to move it, or drag its bottom-right corner to resize it; click **Auto-arrange** to lay everything out cleanly again (column widths and row heights adapt to each panel's current size); click **Export layout as PNG** to save the whole diagram as an image.
8. Double-click a panel's title to rename its population, or double-click a gate's name in the **Gating hierarchy** tree — both edit the same underlying name. Click the color swatch in a panel's header (or next to a gate in the tree) to assign that population a color; click the small **×** next to a colored swatch to reset it to the default look.
9. You can also open/focus a gate's panel from the **Gating hierarchy** tree in the sidebar (creating one if it doesn't have a panel open yet).
10. Once you've built a gating hierarchy on one sample, click **Apply to other samples…** in the Gating hierarchy panel to copy the whole strategy — gates *and* the panel layout that views them — onto other loaded samples (this replaces their existing gates and panels).
11. In the **Statistics** panel at the bottom, pick which two parameters to show medians for, then **Export stats CSV** for the whole table (every gate, including each quadrant) or the ⭳ button on any row to export that population's raw events as CSV.
12. Building a figure? Click **⊞** in any panel's header (in any sample) to add it to the **Layout** section in the sidebar. Click **View Layout →** to switch the main view there, mix in panels from other samples the same way, drag/resize/relabel each one (double-click its title — this only changes the figure caption, not the gate's real name).
13. In a panel's X/Y toolbar (sample workspace or Layout), type into the small text box next to a parameter dropdown to give that axis a custom label (e.g. `GFP` instead of `FL1-A`); clear it to go back to the parameter name.
14. In the Layout, click a panel's header to select it and shift-click others to multi-select; use the **Left/Right/Top/Bottom/Ctr X/Ctr Y** buttons that appear to align the selection, or **Dist X/Dist Y** (3+ panels) to space them evenly. Dragging a panel also snaps to its neighbors' edges/centers automatically. Click **Auto-arrange** for a clean grid, **Export stats CSV** for a per-panel table of counts/%/medians, or **Export layout as PNG** for a publish-ready image.

## Project layout

```
src/
├── fcs/
│   ├── parseFCS.ts      FCS 3.0/3.1 binary parser (HEADER/TEXT/DATA segments)
│   └── types.ts
├── gating/
│   ├── gateTypes.ts      Gate shape/node types (rectangle, polygon, range, quadrant) + optional color
│   ├── gateEval.ts       Point-in-gate tests, ancestor-chain evaluation
│   ├── gateStats.ts      Per-gate count/%/median statistics
│   └── gateClone.ts      Clones a gate hierarchy (+ id map, colors) onto another sample's parameters
├── state/
│   ├── store.ts          zustand store: samples, gate trees, panels, Layout collage, UI selection
│   ├── panelLayout.ts    Panel sizing constants + size-aware auto-layout (tree + grid) algorithms
│   └── types.ts          Sample/Panel/LayoutItem data model (Panel and LayoutItem carry their own width/height)
├── components/
│   ├── FileLoader.tsx      Drag-and-drop / file picker
│   ├── SampleList.tsx      Loaded-sample switcher
│   ├── GateTree.tsx        Gating hierarchy sidebar + "apply to other samples" trigger
│   ├── PanelWorkspace.tsx  The scrollable multi-panel canvas: layout, connector lines, drag/resize, PNG export
│   ├── GatePanel.tsx       A single plot panel: axes, custom axis labels, log toggle, gate drawing/editing/coloring, inline rename, drill-down-to-new-panel
│   ├── LayoutSidebar.tsx   Sidebar section listing Layout items + the samples/layout view switcher
│   ├── LayoutWorkspace.tsx The Layout collage canvas: grid arrangement, drag/resize, multi-select + align/distribute + snap guides, stats CSV + PNG export
│   ├── LayoutPanel.tsx     A read-only-for-gating plot in the Layout (editable axes/custom axis labels/log/label/position/size)
│   ├── StatsTable.tsx      Whole-sample statistics table + CSV export
│   ├── GateNameDialog.tsx  Small modal for naming a new gate
│   └── ApplyGatesDialog.tsx Modal for picking which samples to copy a gating strategy onto
└── utils/
    ├── scale.ts           Linear/log10 domain↔pixel scaling, tick generation
    ├── colormap.ts        Pseudocolor density gradient
    ├── csv.ts             CSV download helper
    ├── exportImage.ts     PNG layout export helper
    └── id.ts               Shared unique-id generator
```

## Known limitations

- There's no shared "workspace" gating tree that stays synchronized across samples — "Apply to other samples" is a one-time copy (of both gates and panel layout); editing gates afterward on one sample doesn't propagate to the others.
- No compensation (spillover matrix). The log axis option is a plain log10 transform floored at 1, not FlowJo's logicle/biexponential.
- Very large files (multi-million events) parse and render on the main thread, so the UI may pause briefly while loading.
