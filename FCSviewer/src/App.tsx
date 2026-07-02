import { useMemo } from 'react';
import { useStore, getActiveSample } from './state/store';
import { FileLoader } from './components/FileLoader';
import { SampleList } from './components/SampleList';
import { GateTree } from './components/GateTree';
import { PlotCanvas } from './components/PlotCanvas';
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
          <FileLoader />
          <SampleList />
          {sample && <GateTree sample={sample} stats={stats} />}
        </aside>
        <main className="main-content">
          {sample ? (
            <>
              <PlotCanvas sample={sample} />
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
