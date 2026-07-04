import { useRef, useState } from 'react';
import { useStore } from '../state/store';
import { serializeProject, deserializeProject, ProjectFileError } from '../project/projectFile';
import { downloadBlob } from '../utils/download';

/**
 * Save/restore the whole workspace — every loaded sample's data, gates, and
 * panels, plus the Layout collage — to a single .fcsproj file, so a session
 * can be picked back up later without re-loading or re-gating the original
 * .fcs files (much like an RStudio .RData workspace).
 */
export function ProjectControls() {
  const { samples, layoutItems, activeSampleId, mainView, notebookText, loadProject } = useStore();
  const inputRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);

  function handleSave() {
    const blob = serializeProject({ samples, layoutItems, activeSampleId, mainView, notebookText });
    const stamp = new Date().toISOString().slice(0, 10);
    downloadBlob(`fcsviewer_project_${stamp}.fcsproj`, blob);
  }

  async function handleFileChosen(file: File) {
    if (samples.length > 0) {
      const ok = window.confirm(
        'Opening a project replaces the samples, gates, and Layout currently loaded. Continue?'
      );
      if (!ok) return;
    }
    setBusy(true);
    setLoadError(null);
    try {
      const project = await deserializeProject(file);
      loadProject(project);
    } catch (e) {
      setLoadError(e instanceof ProjectFileError ? e.message : 'Could not open this project file.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="project-controls">
      <div className="panel-title">Project</div>
      <div className="btn-group">
        <button
          className="btn"
          onClick={handleSave}
          disabled={samples.length === 0}
          title="Save every loaded sample (data, gates, panels) and the Layout collage to a file"
        >
          Save Project…
        </button>
        <button
          className="btn"
          onClick={() => inputRef.current?.click()}
          disabled={busy}
          title="Restore a previously saved project file"
        >
          {busy ? 'Opening…' : 'Open Project…'}
        </button>
      </div>
      <input
        ref={inputRef}
        type="file"
        accept=".fcsproj"
        hidden
        onChange={(e) => {
          const file = e.target.files?.[0];
          if (file) handleFileChosen(file);
          e.target.value = '';
        }}
      />
      {loadError && (
        <div className="error-banner">
          <pre>{loadError}</pre>
          <button className="btn" onClick={() => setLoadError(null)}>
            Dismiss
          </button>
        </div>
      )}
    </div>
  );
}
