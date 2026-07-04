import { useCallback, useEffect, useRef, useState } from 'react';
import { useStore } from '../state/store';
import { serializeProject, deserializeProject, ProjectFileError, type ProjectState } from '../project/projectFile';
import {
  recentProjectsSupported,
  listRecentProjects,
  saveRecentProject,
  loadRecentProject,
  removeRecentProject,
  clearRecentProjects,
  type RecentProjectMeta,
} from '../project/recentProjects';
import { downloadBlob } from '../utils/download';

function formatRelativeTime(iso: string): string {
  const diffMs = Date.now() - new Date(iso).getTime();
  const minutes = Math.round(diffMs / 60000);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  if (days < 7) return `${days}d ago`;
  return new Date(iso).toLocaleDateString();
}

/**
 * Save/restore the whole workspace — every loaded sample's data, gates, and
 * panels, plus the Layout collage — to a single .fcsproj file, so a session
 * can be picked back up later without re-loading or re-gating the original
 * .fcs files (much like an RStudio .RData workspace). Every save/open also
 * keeps a local copy in the browser (IndexedDB) so it shows up under
 * "Recent projects" for one-click reopening, without needing the downloaded
 * file again.
 */
export function ProjectControls() {
  const { samples, layoutItems, activeSampleId, mainView, notebookText, loadProject } = useStore();
  const inputRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [recents, setRecents] = useState<RecentProjectMeta[]>([]);
  const recentsSupported = recentProjectsSupported();

  const refreshRecents = useCallback(() => {
    if (!recentsSupported) return;
    listRecentProjects()
      .then(setRecents)
      .catch(() => setRecents([]));
  }, [recentsSupported]);

  useEffect(() => {
    refreshRecents();
  }, [refreshRecents]);

  function confirmReplaceIfNeeded(): boolean {
    if (samples.length === 0) return true;
    return window.confirm('Opening a project replaces the samples, gates, and Layout currently loaded. Continue?');
  }

  function handleSave() {
    const stamp = new Date().toISOString().slice(0, 10);
    const name = window.prompt('Name this project (used for the download and the recent-projects list):', `fcsviewer_project_${stamp}`);
    if (!name) return;
    const state: ProjectState = { samples, layoutItems, activeSampleId, mainView, notebookText };
    const blob = serializeProject(state);
    downloadBlob(`${name}.fcsproj`, blob);
    if (recentsSupported) {
      saveRecentProject(name, state)
        .then(refreshRecents)
        .catch(() => {
          /* Recording to the recent-projects list is a convenience, not essential — the download already succeeded. */
        });
    }
  }

  async function handleFileChosen(file: File) {
    if (!confirmReplaceIfNeeded()) return;
    setBusy(true);
    setLoadError(null);
    try {
      const project = await deserializeProject(file);
      loadProject(project);
      if (recentsSupported) {
        const name = file.name.replace(/\.fcsproj$/i, '');
        saveRecentProject(name, project)
          .then(refreshRecents)
          .catch(() => {});
      }
    } catch (e) {
      setLoadError(e instanceof ProjectFileError ? e.message : 'Could not open this project file.');
    } finally {
      setBusy(false);
    }
  }

  async function handleOpenRecent(id: string) {
    if (!confirmReplaceIfNeeded()) return;
    setBusy(true);
    setLoadError(null);
    try {
      const project = await loadRecentProject(id);
      loadProject(project);
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : 'Could not open this recent project.');
      refreshRecents();
    } finally {
      setBusy(false);
    }
  }

  function handleRemoveRecent(id: string) {
    removeRecentProject(id)
      .then(refreshRecents)
      .catch(() => {});
  }

  function handleClearRecents() {
    if (!window.confirm('Remove all recent projects from this browser? This does not delete any downloaded .fcsproj files.')) return;
    clearRecentProjects()
      .then(refreshRecents)
      .catch(() => {});
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
      {recentsSupported && recents.length > 0 && (
        <div className="recent-projects">
          <div className="panel-title-row">
            <div className="panel-title">Recent projects</div>
            <button className="btn btn-small" onClick={handleClearRecents} title="Remove all recent projects from this browser">
              Clear
            </button>
          </div>
          <ul className="gate-list">
            {recents.map((r) => (
              <li key={r.id} className="gate-item recent-project-item">
                <span
                  className="gate-name"
                  onClick={() => !busy && handleOpenRecent(r.id)}
                  title={`${r.sampleFileNames.join(', ') || 'No samples'} · saved ${formatRelativeTime(r.savedAt)}`}
                >
                  {r.name}
                  <span className="recent-project-meta">
                    {r.sampleFileNames.length} sample{r.sampleFileNames.length === 1 ? '' : 's'} · {formatRelativeTime(r.savedAt)}
                  </span>
                </span>
                <button className="gate-delete" title="Remove from recent projects" onClick={() => handleRemoveRecent(r.id)}>
                  ×
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
