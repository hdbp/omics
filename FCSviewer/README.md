# FCS Viewer

A lightweight, standalone viewer for flow cytometry `.fcs` files that mimics FlowJo's core workflow: load data, build a layout of linked plots by drilling into gates, and view live statistics. It's a static React/TypeScript single-page app — there is no backend, and files never leave the browser. Ships as a portable browser build and as a native macOS/Linux desktop app (see "Running it" below) — both built from the same source.

## Features

- **Load `.fcs` files** — drag-and-drop or file picker, multiple samples at once. Supports FCS 3.0/3.1 list-mode files with `INT`/`FLOAT`/`DOUBLE` data types and byte-aligned parameter widths (8/16/32/64-bit).
- **Import straight from Dropbox** (optional) — an **Import from Dropbox…** button next to the dropzone opens Dropbox's own file picker and loads `.fcs` files directly into the browser, no download-then-upload round trip. Off by default; see "Cloud storage integration" below to turn it on. Files still go straight from Dropbox to your browser — this app has no server of its own to route them through.
- **A workspace of linked plots, not one plot that swaps in place** — like FlowJo, each sample gets a canvas of "panels." Every panel is a dot plot or histogram bound permanently to one population, with its own X/Y axes, log/linear scale, and plot type.
- **Gate, then drill down into a brand-new panel** — draw a rectangle/polygon gate on a panel (e.g. FSC-A vs SSC-A), then click the gated region to open it in a *new* panel, connected to its parent by a line. Pick different axes there (e.g. GFP vs BFP) and gate again — each drill-down spawns another linked panel, building out the full gating tree visually.
- **Gates stay editable after you've drilled into them** — every rectangle/polygon/range gate shows small drag handles on the panel you drew it on. Drag a handle to reshape it, or drag its body to move it; any panel already drilled into that population (or a descendant of it) recomputes its events and stats live, no need to redraw or re-drill.
- **A movable %parent/%total stats annotation on every panel** — each panel (in a sample's workspace or the Layout) shows a small badge with the population's % of parent and % of total, live-updating as you gate, quadrant, or drill down. Drag the badge anywhere on the plot so it doesn't sit on top of the data (or get hidden behind it).
- **Resize, rearrange, and export the layout** — drag any panel by its header to reposition it, drag its bottom-right corner to resize it, click **Auto-arrange** to snap everything back to a clean tree layout (respecting each panel's current size), and **Export layout as PNG** to save the whole assembled panel-and-connector diagram as one image.
- **Label panels and color populations** — double-click a panel's title to rename its population (shared with the gate tree). Click the small color swatch in a panel's header or next to a gate in the tree to assign it a color: child-gate outlines/quadrant labels are drawn in their assigned color, and a panel showing a colored population renders its own events in that flat color instead of the default density heatmap.
- **Quadrant gates, with stats shown right on the plot** — click-drag to place a crosshair on a dot plot, splitting it into 4 populations (auto-named by +/- for each axis) with a single gesture. Each quadrant's count and % of parent are printed right next to its name on the plot itself (live in the sample workspace and the Layout, and baked into the PNG export in either theme) — not just in the statistics table below. Drag the crosshair intersection afterward to reposition all 4 at once, with the on-plot numbers updating live; every quadrant is a regular gate, so it also gets its own row (count, %parent, %total, median) in the statistics table and can itself be drilled into.
- **Log axis scale** — toggle **log X** / **log Y** per panel independently (log10, floored at 1) — useful for fluorescence channels that are hard to read on a linear scale.
- **Apply a gating strategy to other samples** — clone the active sample's entire gate hierarchy *and panel layout* onto other loaded samples in one step: the same chain of linked panels (axes, plot type, log scale, position) is recreated on each target, recomputed against its own data. If a target sample already had its own gate in the same position in the hierarchy, its existing name is kept (only the shape/boundary and panel layout are replaced); a position with no prior gate falls back to the source's name. Gates/panels that depend on a parameter missing from a target sample are skipped (with a summary of what was skipped), rather than applied broken.
- **Statistics table** — count, % of parent, % of total, and median (for two parameters you choose) for every gate across the whole sample, live-updating as you gate. Export the table, or any single population's raw events, as CSV.
- **A dedicated Layout collage for publication figures** — a separate "Layout" section in the sidebar, independent of any one sample's analysis workspace. Click **⊞** in any panel's header (in any sample) to add a curated copy of it — its own axes, plot type, and a free-text caption — to the Layout. Mix panels from different samples, drag/resize/relabel them, click **Auto-arrange** for a clean grid, and export the whole collage as a **PNG**, **PDF**, or **PowerPoint (.pptx)** file.
- **Custom axis labels** — type into the small text box next to a panel's X/Y parameter dropdown (in either a sample's workspace or the Layout) to override what's printed on the plot axis, e.g. swap a laser/detector name like `FL1-A` for `GFP`. Leave it blank to fall back to the parameter name. Carries over automatically when a panel is added to the Layout.
- **Layout alignment helpers** — click a panel's header in the Layout to select it, shift-click to add more to the selection; a toolbar appears to align the selection's edges or centers (**Left/Right/Top/Bottom/Ctr X/Ctr Y**) or **Dist X/Dist Y** to space 3+ selected panels evenly. Dragging any panel also snaps to nearby panels' edges/centers (within a few pixels) and shows a dashed guide line while it's snapped. Click empty canvas space to clear the selection.
- **Layout population statistics export** — **Export stats CSV** in the Layout toolbar writes one row per panel in the collage: sample, population path, event count, % of parent, % of total, and median of each axis parameter (using its custom label if set) — everything you need to caption a figure with real numbers.
- **Choose which stats print under each Layout panel** — click **Stats ▾** on a Layout panel to pick which fields (population path, count, % parent, % total, median X, median Y) appear as a text line under its plot. Baked into every export format, so the exported figure carries the numbers, not just the plot.
- **Light or dark background on export** — the app's own UI is always dark, but the Layout's export controls (and the sample workspace's **Export layout as PNG**) have a **Light bg / Dark bg** toggle next to them. Light re-renders the whole figure — panel chrome, axes, ticks, gate outlines, the stats badge — in publication-friendly colors (white background, dark text) instead of a screenshot of the dark UI; the density colormap and any custom gate colors are unchanged either way.
- **Export the Layout as PNG, PDF, or PowerPoint** — **Export as PNG** downloads the collage as a raster image (as before); **Export as PDF** wraps the same rendered figure in a single-page PDF sized to match it exactly, no extra margins; **Export as PowerPoint** drops it into a single slide of a `.pptx` file, sized to the figure's own aspect ratio rather than a fixed 4:3/16:9, ready to paste into a deck or drag panels around further in PowerPoint. All three re-render the collage from scratch at 2x resolution (not a screenshot) and respect whichever **Light bg/Dark bg** theme is selected. The PDF/PPTX libraries are only downloaded the first time you use those buttons, so they don't add to the initial page-load size.
- **Save/open a project, like an RStudio workspace** — **Save Project…** in the sidebar writes every loaded sample's *raw event data* plus its gates, panels, colors, axis labels, and stats-annotation positions, and the whole Layout collage, to a single `.fcsproj` file. **Open Project…** restores all of it exactly — you don't need the original `.fcs` files again to pick up where you left off.
- **Contour/density gate tool** — click the **≈** tool on a dot plot, then hover over a density region: its outline at the current sensitivity is traced live (the same pseudocolor density grid the plot already renders from, contoured with marching squares) and previewed as a dashed loop. Scroll to make the contour tighter (higher-density core) or looser (more inclusive); click to turn the previewed outline into a gate. A contour gate is a regular polygon gate once created — it gets drag handles, a color swatch, a row in the statistics table, and survives drilling down, "Apply to other samples," Layout, PNG export, and project save/load exactly like one drawn by hand.
- **Choose the density pseudocolor palette** — a **Colors** dropdown on every dot-plot panel (sample workspace, Layout, and baked into PNG export) switches the density heatmap between Rainbow (the default FlowJo-style jet palette), Viridis, Plasma, Fire, and Grayscale. Set independently per panel; carried over to the Layout and to "Apply gating strategy to other samples."
- **Format panel fonts** — **Font** and **Size** controls on every panel change the typeface (System UI, Arial, Georgia, Times New Roman, Courier New, or Verdana) and size (8–20px) used for axis labels, tick numbers, gate/quadrant labels, and the stats annotation — live in the workspace, the Layout, and PNG export. Set independently per panel; carried over to the Layout and to "Apply gating strategy to other samples."
- **A Notebook for notes about the assay** — a "Notebook" section in the sidebar opens a full-width, free-text notes area (protocol, panel/antibody design, compensation notes, run deviations, anything worth remembering) shared across the whole project rather than tied to one sample. Saved and restored with **Save Project…**/**Open Project…** like everything else.
- **Overlay panels to contrast samples (Layout only)** — right-click a Layout panel's plot to open a context menu, hover **Overlay ▸** for a submenu listing every other panel currently in the Layout, and click one to draw that panel's population on top of this one, on the same axes. Click an already-added entry again (shown with a ✓) to remove just that overlay, or use **Clear overlays** to remove them all. Overlaid samples always render in flat, automatically-distinct colors (never each other's pseudocolor density gradient, which would be meaningless once multiple samples share a plot and could make different samples look confusingly similar) — a small legend in the corner of the plot shows which color belongs to which sample. Works for both dot plots (semi-transparent flat-colored points) and histograms (outlined, not filled, so overlapping distributions stay readable). Baked into PNG/PDF/PowerPoint export in either theme.

Not included in this version: compensation/spillover matrices and full biexponential/logicle transforms — the log option is a straight log10 (floored at 1), not FlowJo's logicle.

## Running it

```bash
cd FCSviewer
npm install
npm run dev
```

Then open the printed local URL.

FCS Viewer ships in two forms, built from the exact same source:

### 1. Portable (runs in any browser)

A static production build — no install, just open it, works on macOS, Linux, Windows, or served from any static host:

```bash
npm run build     # outputs to dist/
npm run preview   # serve the production build locally to try it
```

`dist/` is a self-contained set of static files (HTML/JS/CSS) — copy that folder anywhere (a USB drive, an internal file share, GitHub Pages, S3, etc.) and open `index.html` in a browser, or serve it with any static file server.

### 2. Native desktop app (macOS `.dmg`, Linux `.deb`/`.AppImage`)

The same web app wrapped by [Tauri](https://tauri.app) into a real installable app — a dock icon, its own window (no browser chrome), and no `npm install`/terminal needed for end users. It uses each OS's built-in system webview (WebKit on macOS, WebKitGTK on Linux), so the installer is a few MB of Rust glue on top of the ~80KB app bundle, not a bundled browser engine.

```bash
npm run desktop:dev     # run it as a desktop window during development
npm run desktop:build   # build the installer(s) for the OS you're running on
```

`desktop:build` only produces installers for the platform it runs *on* (there's no cross-compiling a `.dmg` from Linux or vice versa) — run it on a Mac for the `.dmg`/`.app`, or on Linux for the `.deb`/`.AppImage`. The `src-tauri/` folder holds the wrapper config; the actual app code is 100% the same `src/` used by the portable build, and it doesn't need any Tauri-specific APIs since file loading already goes through the browser's own File API.

**Building both without owning a Mac:** push a tag like `fcsviewer-v0.1.0`, or run the **FCS Viewer desktop build** workflow manually from the Actions tab — `.github/workflows/fcsviewer-desktop.yml` builds the macOS (universal, Intel + Apple Silicon) `.dmg` and the Linux `.deb`/`.AppImage` in parallel on GitHub's own macOS/Linux runners and uploads them as workflow artifacts (and as a draft GitHub Release when triggered by the tag). The macOS build isn't code-signed/notarized (no Apple Developer account configured), so first launch will need a right-click → **Open** to bypass Gatekeeper's "unidentified developer" warning.

### Cloud storage integration (optional)

The **Import from Dropbox…** button is hidden unless you configure a Dropbox app key — there's no shared/default key baked into the app, since Chooser keys are tied to specific domains.

1. Create an app at [dropbox.com/developers/apps](https://www.dropbox.com/developers/apps) — "Scoped access", any access type (Chooser doesn't use API scopes).
2. In the app's settings, under **Chooser/Saver/Embedder domains**, add every domain/port you'll run this from — `localhost:5173` for `npm run dev`, plus wherever you deploy the portable build. Chooser needs http(s); it won't work opening `dist/index.html` directly via `file://`, and (untested) may not work inside the Tauri desktop app's webview either, since Chooser opens a popup window.
3. Copy the app key from the app's settings page into `FCSviewer/.env.local` (gitignored — never commit a real key):
   ```
   VITE_DROPBOX_APP_KEY=your-app-key-here
   ```
4. Restart `npm run dev` (Vite only reads `.env*` files at startup) — the button appears once a key is present.

Google Drive and OneDrive aren't wired up yet; Dropbox was the simplest to start with since its Chooser widget needs no OAuth redirect URI (unlike Drive's Picker or OneDrive's picker SDK), which fits a purely static app that might be opened from any URL.

## Usage

1. Drop one or more `.fcs` files onto the panel on the left (or click it to browse). Each sample opens with one root panel showing all events.
2. In a panel, pick X/Y parameters from its dropdowns, switch between **Dot plot** and **Histogram**, and toggle **log X**/**log Y** as needed.
3. Click the **▭** (rectangle), **⬠** (polygon), **✛** (quadrant), **≈** (contour, dot plots only), or **↔** (range, histogram only) button, then draw on that panel's plot:
   - Rectangle/range: click-drag.
   - Polygon: click to add each vertex, then click near the first vertex, double-click, or press <kbd>Enter</kbd> to close it. <kbd>Esc</kbd> cancels.
   - Quadrant (dot plots only): click-drag to place the crosshair, release to instantly create all 4 quadrant gates (auto-named, no dialog) — each one's count and % of parent appear right next to its name on the plot. Afterward, drag the crosshair intersection again (with no tool active) to reposition all 4 together — the on-plot numbers update live.
   - Contour (dot plots only): hover over a density region to preview its outline (traced from the same density grid the plot renders), scroll to tighten or loosen the sensitivity (shown as a % in the hint text), then click to turn the previewed outline into a gate — named like any other gate and just as editable afterward.
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
14. In the Layout, click a panel's header to select it and shift-click others to multi-select; use the **Left/Right/Top/Bottom/Ctr X/Ctr Y** buttons that appear to align the selection, or **Dist X/Dist Y** (3+ panels) to space them evenly. Dragging a panel also snaps to its neighbors' edges/centers automatically. Click **Auto-arrange** for a clean grid, **Export stats CSV** for a per-panel table of counts/%/medians, or **Export as PNG** / **Export as PDF** / **Export as PowerPoint** for a publish-ready figure in whichever format you need.
15. Every panel shows a small **%parent/%total badge** on its plot — drag it (by clicking directly on the badge) to wherever it won't sit on top of your data; this is separate from dragging the panel itself, which only happens from the header.
16. On a Layout panel, click **Stats ▾** to check/uncheck which fields (population path, count, %parent, %total, median X, median Y) show as a line of text under the plot — and in the exported PNG.
17. Before exporting a PNG (sample workspace or Layout), pick **Light bg** or **Dark bg** next to the export button — Light re-renders the whole figure in white/dark-text for a publication-ready image, independent of the app's own (always-dark) interface.
18. Click **Save Project…** at the top of the sidebar any time to download a `.fcsproj` file with everything currently loaded — samples' raw data, gates, panels, colors, custom axis labels, the Layout collage, and the Notebook. Later, click **Open Project…** and pick that file to restore the exact same workspace (confirms first if you already have samples loaded, since it replaces them).
19. If you've configured a Dropbox app key (see "Cloud storage integration"), click **Import from Dropbox…** next to the dropzone to pick `.fcs` files straight out of your Dropbox instead of downloading them first.
20. On any dot-plot panel, use the **Colors** dropdown to switch the density heatmap palette (Rainbow/Viridis/Plasma/Fire/Grayscale) — set per panel, carried over to the Layout and PNG export.
21. Use the **Font** dropdown and **Size** field on any panel to change the typeface and size used for axis labels, tick numbers, and gate/stats text — set per panel, carried over to the Layout and PNG export.
22. Click **View Notebook →** in the sidebar's **Notebook** section to open a full-width notes area — jot down anything about the assay (panel design, compensation, deviations); it's shared across all loaded samples, previewed in the sidebar, and saved/restored with the project file.
23. In the Layout, right-click any panel's plot to open its context menu, hover **Overlay ▸**, and click another panel from the list to draw that panel's sample on top of this one (same axes) in its own flat color — useful for contrasting two samples (e.g. control vs. treated) on one plot. Click a checked entry again to remove it, or **Clear overlays** to remove all of them; a legend in the corner shows which color is which sample.

## Project layout

```
src/
├── fcs/
│   ├── parseFCS.ts      FCS 3.0/3.1 binary parser (HEADER/TEXT/DATA segments)
│   └── types.ts
├── gating/
│   ├── gateTypes.ts      Gate shape/node types (rectangle, polygon, range, quadrant) + optional color
│   ├── gateEval.ts       Point-in-gate tests, ancestor-chain evaluation
│   ├── gateStats.ts      Per-gate count/%/median statistics; shared formatting for the Layout stats block/CSV/PNG export; per-quadrant stats grouping
│   ├── gateClone.ts      Clones a gate hierarchy (+ id map, colors) onto another sample's parameters
│   └── contour.ts        Marching-squares density contour tracing + point-in-polygon, for the contour gate tool
├── state/
│   ├── store.ts          zustand store: samples, gate trees, panels, Layout collage, UI selection
│   ├── panelLayout.ts    Panel sizing constants + size-aware auto-layout (tree + grid) algorithms
│   └── types.ts          Sample/Panel/LayoutItem data model (Panel and LayoutItem carry their own width/height)
├── project/
│   └── projectFile.ts      .fcsproj save/restore: JSON metadata header + raw float32 event-data columns, no base64 bloat
├── integrations/
│   └── dropbox.ts          Dropbox Chooser: script loading + a Promise wrapper around the popup file picker
├── components/
│   ├── ProjectControls.tsx Save/Open Project buttons (the whole workspace, à la an RStudio .RData workspace)
│   ├── FileLoader.tsx      Drag-and-drop / file picker
│   ├── SampleList.tsx      Loaded-sample switcher
│   ├── GateTree.tsx        Gating hierarchy sidebar + "apply to other samples" trigger
│   ├── PanelWorkspace.tsx  The scrollable multi-panel canvas: layout, connector lines, drag/resize, light/dark PNG export
│   ├── GatePanel.tsx       A single plot panel: axes, custom axis labels, log toggle, gate drawing/editing/coloring, inline rename, drill-down-to-new-panel
│   ├── LayoutSidebar.tsx   Sidebar section listing Layout items + the samples/layout view switcher
│   ├── LayoutWorkspace.tsx The Layout collage canvas: grid arrangement, drag/resize, multi-select + align/distribute + snap guides, stats CSV + light/dark PNG export
│   ├── LayoutPanel.tsx     A read-only-for-gating plot in the Layout (editable axes/custom axis labels/log/label/position/size); right-click context menu for overlaying other panels' samples
│   ├── StatsTable.tsx      Whole-sample statistics table + CSV export
│   ├── Notebook.tsx        Full-width free-text notes area for the whole project (assay/protocol notes)
│   ├── NotebookSidebar.tsx Sidebar section: notes preview + the samples/notebook view switcher
│   ├── GateNameDialog.tsx  Small modal for naming a new gate
│   └── ApplyGatesDialog.tsx Modal for picking which samples to copy a gating strategy onto
└── utils/
    ├── scale.ts           Linear/log10 domain↔pixel scaling, tick generation
    ├── colormap.ts        Pseudocolor density gradients (Rainbow/Viridis/Plasma/Fire/Grayscale)
    ├── overlayColors.ts    Fixed distinguishable flat-color palette for overlaying samples in the Layout
    ├── fonts.ts            Shared font-family/size options + label/tick font resolution for panels
    ├── csv.ts             CSV download helper
    ├── exportImage.ts     PNG layout export helper
    ├── exportDoc.ts        PDF/PowerPoint layout export (jsPDF/PptxGenJS, dynamically imported on first use)
    ├── theme.ts            Light/dark color palettes for PNG export
    ├── plotRender.ts       Re-renders a panel's plot onto an export canvas in either theme, independent of the live (always-dark) DOM canvas
    ├── download.ts         Shared Blob-download helper
    └── id.ts               Shared unique-id generator

src-tauri/                  Native desktop wrapper (Tauri) — config + a few lines of Rust; loads dist/ into an OS webview
├── tauri.conf.json         Window size, bundle targets (dmg/app/deb/appimage), icons, product metadata
├── Cargo.toml / src/       Minimal Rust entry point — no custom commands; the app doesn't need any Tauri-specific APIs
└── icons/                  App icons (currently the Tauri defaults — swap in real artwork before a real release)
```

`.github/workflows/fcsviewer-desktop.yml` builds the desktop installers in CI (see "Native desktop app" above).

## Known limitations

- There's no shared "workspace" gating tree that stays synchronized across samples — "Apply to other samples" is a one-time copy (of both gates and panel layout); editing gates afterward on one sample doesn't propagate to the others.
- No compensation (spillover matrix). The log axis option is a plain log10 transform floored at 1, not FlowJo's logicle/biexponential.
- Very large files (multi-million events) parse and render on the main thread, so the UI may pause briefly while loading.
- Dropbox import is untested inside the Tauri desktop build — Chooser opens a popup window, which webviews don't always handle the same way browsers do. Google Drive/OneDrive aren't implemented yet.
- The desktop build isn't code-signed or notarized (no Apple Developer account configured) and uses placeholder icons — fine for internal/personal use, but a real release would want both before wide distribution.
- `.fcsproj` is a custom format specific to this app (not a standard flow cytometry format), versioned internally — a project saved by a much newer/older build may refuse to open if the format changes. It embeds full event data, so file size is roughly the sum of the original `.fcs` files' sizes.
