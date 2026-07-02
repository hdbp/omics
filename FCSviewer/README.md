# FCS Viewer

A lightweight, standalone, in-browser viewer for flow cytometry `.fcs` files that mimics FlowJo's core workflow: load data, build a layout of linked plots by drilling into gates, and view live statistics. It's a static React/TypeScript single-page app — there is no backend, and files never leave the browser.

## Features

- **Load `.fcs` files** — drag-and-drop or file picker, multiple samples at once. Supports FCS 3.0/3.1 list-mode files with `INT`/`FLOAT`/`DOUBLE` data types and byte-aligned parameter widths (8/16/32/64-bit).
- **A workspace of linked plots, not one plot that swaps in place** — like FlowJo, each sample gets a canvas of "panels." Every panel is a dot plot or histogram bound permanently to one population, with its own X/Y axes, log/linear scale, and plot type.
- **Gate, then drill down into a brand-new panel** — draw a rectangle/polygon gate on a panel (e.g. FSC-A vs SSC-A), then click the gated region to open it in a *new* panel, connected to its parent by a line. Pick different axes there (e.g. GFP vs BFP) and gate again — each drill-down spawns another linked panel, building out the full gating tree visually.
- **Rearrange and export the layout** — drag any panel by its header to reposition it, click **Auto-arrange** to snap back to a clean tree layout, and **Export layout as PNG** to save the whole assembled panel-and-connector diagram as one image.
- **Log axis scale** — toggle **log X** / **log Y** per panel independently (log10, floored at 1) — useful for fluorescence channels that are hard to read on a linear scale.
- **Apply a gating strategy to other samples** — clone the active sample's entire gate hierarchy onto other loaded samples in one step. Gates that depend on a parameter missing from a target sample are skipped (with a summary of what was skipped), rather than applied broken.
- **Statistics table** — count, % of parent, % of total, and median (for two parameters you choose) for every gate across the whole sample, live-updating as you gate. Export the table, or any single population's raw events, as CSV.

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
3. Click the **▭** (rectangle), **⬠** (polygon), or **↔** (range, histogram only) button, then draw on that panel's plot:
   - Rectangle/range: click-drag.
   - Polygon: click to add each vertex, then click near the first vertex, double-click, or press <kbd>Enter</kbd> to close it. <kbd>Esc</kbd> cancels.
4. Name the gate when prompted. Its outline appears on the panel you drew it on.
5. **Click inside the gated region** (with no drawing tool active) to drill down — this opens a *new panel* for that population, connected to the one you drew from, with fresh default axes so you can immediately pick different channels (e.g. GFP/BFP). Repeat to build out the full gating tree as a chain of linked panels.
6. Drag a panel by its header to move it; click **Auto-arrange** to lay everything out cleanly again; click **Export layout as PNG** to save the whole diagram as an image.
7. You can also open/focus a gate's panel from the **Gating hierarchy** tree in the sidebar (creating one if it doesn't have a panel open yet), and double-click a gate's name there to rename it.
8. Once you've built a gating hierarchy on one sample, click **Apply to other samples…** in the Gating hierarchy panel to copy the whole strategy onto other loaded samples (this replaces their existing gates and panels).
9. In the **Statistics** panel at the bottom, pick which two parameters to show medians for, then **Export stats CSV** for the whole table or the ⭳ button on any row to export that population's raw events as CSV.

## Project layout

```
src/
├── fcs/
│   ├── parseFCS.ts      FCS 3.0/3.1 binary parser (HEADER/TEXT/DATA segments)
│   └── types.ts
├── gating/
│   ├── gateTypes.ts      Gate shape/node types (rectangle, polygon, range)
│   ├── gateEval.ts       Point-in-gate tests, ancestor-chain evaluation
│   ├── gateStats.ts      Per-gate count/%/median statistics
│   └── gateClone.ts      Clones a gate hierarchy onto another sample's parameters
├── state/
│   ├── store.ts          zustand store: samples, gate trees, panels, UI selection
│   ├── panelLayout.ts    Panel sizing constants + auto-layout (tree) algorithm
│   └── types.ts          Sample/Panel data model
├── components/
│   ├── FileLoader.tsx      Drag-and-drop / file picker
│   ├── SampleList.tsx      Loaded-sample switcher
│   ├── GateTree.tsx        Gating hierarchy sidebar + "apply to other samples" trigger
│   ├── PanelWorkspace.tsx  The scrollable multi-panel canvas: layout, connector lines, drag, PNG export
│   ├── GatePanel.tsx       A single plot panel: axes, log toggle, gate drawing, drill-down-to-new-panel
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

- There's no shared "workspace" gating tree that stays synchronized across samples — "Apply to other samples" is a one-time copy; editing gates afterward on one sample doesn't propagate to the others.
- No compensation (spillover matrix). The log axis option is a plain log10 transform floored at 1, not FlowJo's logicle/biexponential.
- Very large files (multi-million events) parse and render on the main thread, so the UI may pause briefly while loading.
