import { useEffect, useMemo, useRef, useState } from 'react';
import { useStore, getActiveSample } from './state/store';
import { ProjectControls } from './components/ProjectControls';
import { FileLoader } from './components/FileLoader';
import { SampleList } from './components/SampleList';
import { GateTree } from './components/GateTree';
import { PanelWorkspace } from './components/PanelWorkspace';
import { LayoutWorkspace } from './components/LayoutWorkspace';
import { LayoutSidebar } from './components/LayoutSidebar';
import { Notebook } from './components/Notebook';
import { NotebookSidebar } from './components/NotebookSidebar';
import { StatsTable } from './components/StatsTable';
import { computeGateStats } from './gating/gateStats';
import './App.css';

// Below these, the workspace's own resize handle could never fully escape into view even by
// scrolling, so the splitter refuses to shrink the workspace (or grow the stats panel) past them.
const MIN_STATS_HEIGHT = 100;
const MIN_WORKSPACE_HEIGHT = 380; // matches .panel-workspace-wrap's own CSS min-height
const SPLITTER_ALLOWANCE = 24;

function App() {
  const state = useStore();
  const sample = getActiveSample(state);
  const stats = useMemo(() => (sample ? computeGateStats(sample) : []), [sample]);
  const mainContentRef = useRef<HTMLDivElement>(null);
  const statsPanelRef = useRef<HTMLDivElement>(null);
  const [statsHeight, setStatsHeight] = useState<number | null>(null);
  const [splitterDrag, setSplitterDrag] = useState<{ startY: number; startHeight: number } | null>(null);

  useEffect(() => {
    if (!splitterDrag) return;
    function onMove(e: MouseEvent) {
      if (!splitterDrag) return;
      const dy = e.clientY - splitterDrag.startY;
      const containerHeight = mainContentRef.current?.clientHeight ?? Infinity;
      const maxStatsHeight = Math.max(MIN_STATS_HEIGHT, containerHeight - MIN_WORKSPACE_HEIGHT - SPLITTER_ALLOWANCE);
      setStatsHeight(Math.min(maxStatsHeight, Math.max(MIN_STATS_HEIGHT, splitterDrag.startHeight - dy)));
    }
    function onUp() {
      setSplitterDrag(null);
    }
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
    return () => {
      window.removeEventListener('mousemove', onMove);
      window.removeEventListener('mouseup', onUp);
    };
  }, [splitterDrag]);

  return (
    <div className="app">
      <header className="app-header">
        <h1>FCS Viewer</h1>
        <span className="app-subtitle">A lightweight, in-browser flow cytometry (.fcs) viewer &amp; gating tool</span>
      </header>
      <div className="app-body">
        <aside className="sidebar">
          <ProjectControls />
          <FileLoader />
          {state.notice && (
            <div className="notice-banner">
              <pre>{state.notice}</pre>
              <button className="btn" onClick={state.clearNotice}>
                Dismiss
              </button>
            </div>
          )}
          <SampleList />
          {sample && state.mainView === 'samples' && <GateTree sample={sample} stats={stats} />}
          <LayoutSidebar />
          <NotebookSidebar />
        </aside>
        <main className="main-content" ref={mainContentRef}>
          {state.mainView === 'layout' ? (
            <LayoutWorkspace />
          ) : state.mainView === 'notebook' ? (
            <Notebook />
          ) : sample ? (
            <>
              <PanelWorkspace sample={sample} style={statsHeight != null ? { flex: '1 1 auto' } : undefined} />
              <div
                className="main-splitter"
                title="Drag to resize the statistics panel; double-click to reset"
                onMouseDown={(e) => {
                  e.preventDefault();
                  setSplitterDrag({
                    startY: e.clientY,
                    startHeight: statsPanelRef.current?.getBoundingClientRect().height ?? 200,
                  });
                }}
                onDoubleClick={() => setStatsHeight(null)}
              />
              <StatsTable
                sample={sample}
                stats={stats}
                ref={statsPanelRef}
                style={statsHeight != null ? { flex: '0 0 auto', height: statsHeight, minHeight: MIN_STATS_HEIGHT } : undefined}
              />
            </>
          ) : (
            <div className="empty-state">
              <p>Load one or more .fcs files to get started.</p>
              <p className="empty-state-hint">
                Everything runs locally in your browser — files are never uploaded anywhere.
              </p>
            </div>
          )}
        </main>
      </div>
    </div>
  );
}

export default App;
