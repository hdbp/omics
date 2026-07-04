import { useMemo } from 'react';
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

function App() {
  const state = useStore();
  const sample = getActiveSample(state);
  const stats = useMemo(() => (sample ? computeGateStats(sample) : []), [sample]);

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
        <main className="main-content">
          {state.mainView === 'layout' ? (
            <LayoutWorkspace />
          ) : state.mainView === 'notebook' ? (
            <Notebook />
          ) : sample ? (
            <>
              <PanelWorkspace sample={sample} />
              <StatsTable sample={sample} stats={stats} />
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
