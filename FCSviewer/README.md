# FCS Viewer

A lightweight, standalone, in-browser viewer for flow cytometry `.fcs` files that mimics FlowJo's core workflow: load data, plot channels, draw gates, and view live statistics. It's a static React/TypeScript single-page app — there is no backend, and files never leave the browser.

## Features

- **Load `.fcs` files** — drag-and-drop or file picker, multiple samples at once. Supports FCS 3.0/3.1 list-mode files with `INT`/`FLOAT`/`DOUBLE` data types and byte-aligned parameter widths (8/16/32/64-bit).
- **Dot plots & histograms** — any two parameters as a pseudocolor density dot plot, or any single parameter as a histogram. Each axis can be toggled between linear and log10 scale (useful for fluorescence channels), independently per sample.
- **Interactive gating** — draw rectangle or polygon gates on dot plots, or range (interval) gates on histograms. Gates form a parent → child hierarchy per sample, just like a FlowJo workspace; selecting a gate shows that population and lets you draw child gates on it.
- **Drill-down navigation** — click directly on a gated region drawn on the plot to jump into that population (no need to use the tree), and use the breadcrumb trail above the plot to navigate back up.
- **Apply a gating strategy to other samples** — clone the active sample's entire gate hierarchy onto other loaded samples in one step. Gates that depend on a parameter missing from a target sample are skipped (with a summary of what was skipped), rather than applied broken.
- **Statistics table** — count, % of parent, % of total, and median of the current X/Y parameters for every gate, live-updating as you gate.
- **CSV export** — export the statistics table, or the raw event data for the currently selected population.

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

1. Drop one or more `.fcs` files onto the panel on the left (or click it to browse).
2. Pick X/Y parameters from the dropdowns above the plot, and switch between **Dot plot** and **Histogram**.
3. Click **Rectangle gate** or **Polygon gate** (or **Range gate** in histogram mode), then draw on the plot:
   - Rectangle/range: click-drag.
   - Polygon: click to add each vertex, then click near the first vertex, double-click, or press <kbd>Enter</kbd> to close it. <kbd>Esc</kbd> cancels.
4. Name the gate when prompted. It appears in the **Gating hierarchy** panel as a child of whatever population you were viewing.
5. Click any gate in the hierarchy — or click directly on its drawn outline in the plot — to drill into that population and draw further child gates on it. Use the breadcrumb trail above the plot, or the tree, to navigate back up. Double-click a gate name to rename it.
6. Toggle **log X** / **log Y** to switch either axis to a log10 scale, e.g. for fluorescence channels that are hard to read on a linear scale.
7. Once you've built a gating hierarchy on one sample, click **Apply to other samples…** in the Gating hierarchy panel to copy the whole strategy onto other loaded samples (this replaces their existing gates).
8. Use **Export stats CSV** / **Export gated events CSV** in the Statistics panel to download results.

## Project layout

```
src/
├── fcs/
│   ├── parseFCS.ts      FCS 3.0/3.1 binary parser (HEADER/TEXT/DATA segments)
│   └── types.ts
├── gating/
│   ├── gateTypes.ts      Gate shape/node types (rectangle, polygon, range)
│   ├── gateEval.ts       Point-in-gate tests, ancestor-chain evaluation, breadcrumb chain
│   ├── gateStats.ts      Per-gate count/%/median statistics
│   └── gateClone.ts      Clones a gate hierarchy onto another sample's parameters
├── state/
│   ├── store.ts          zustand store: samples, gate trees, UI selection
│   └── types.ts
├── components/
│   ├── FileLoader.tsx      Drag-and-drop / file picker
│   ├── SampleList.tsx      Loaded-sample switcher
│   ├── GateTree.tsx        Gating hierarchy sidebar + "apply to other samples" trigger
│   ├── PlotCanvas.tsx      Canvas-based dot plot / histogram, gate drawing, log axes, drill-down, breadcrumb
│   ├── StatsTable.tsx      Per-gate statistics + CSV export
│   ├── GateNameDialog.tsx  Small modal for naming a new gate
│   └── ApplyGatesDialog.tsx Modal for picking which samples to copy a gating strategy onto
└── utils/
    ├── scale.ts           Linear/log10 domain↔pixel scaling, tick generation
    ├── colormap.ts        Pseudocolor density gradient
    ├── csv.ts             CSV download helper
    └── id.ts               Shared unique-id generator
```

## Known limitations

- There's no shared "workspace" gating tree that stays synchronized across samples — "Apply to other samples" is a one-time copy; editing gates afterward on one sample doesn't propagate to the others.
- No compensation (spillover matrix). The log axis option is a plain log10 transform floored at 1, not FlowJo's logicle/biexponential.
- Very large files (multi-million events) parse and render on the main thread, so the UI may pause briefly while loading.
