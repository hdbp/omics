import { useRef, useState } from 'react';
import { useStore } from '../state/store';
import { chooseDropboxFiles, fetchDropboxFile } from '../integrations/dropbox';

const DROPBOX_APP_KEY = import.meta.env.VITE_DROPBOX_APP_KEY;

export function FileLoader() {
  const { loadFiles, loading, error, clearError } = useStore();
  const inputRef = useRef<HTMLInputElement>(null);
  const [dragOver, setDragOver] = useState(false);
  const [dropboxBusy, setDropboxBusy] = useState(false);
  const [dropboxError, setDropboxError] = useState<string | null>(null);

  async function handleImportFromDropbox() {
    if (!DROPBOX_APP_KEY) return;
    setDropboxError(null);
    setDropboxBusy(true);
    try {
      const chosen = await chooseDropboxFiles(DROPBOX_APP_KEY);
      if (chosen.length === 0) return;
      const files = await Promise.all(chosen.filter((f) => !f.isDir).map(fetchDropboxFile));
      if (files.length > 0) loadFiles(files);
    } catch (e) {
      setDropboxError(e instanceof Error ? e.message : 'Could not import files from Dropbox.');
    } finally {
      setDropboxBusy(false);
    }
  }

  return (
    <div className="file-loader">
      <div
        className={`dropzone ${dragOver ? 'dropzone-over' : ''}`}
        onClick={() => inputRef.current?.click()}
        onDragOver={(e) => {
          e.preventDefault();
          setDragOver(true);
        }}
        onDragLeave={() => setDragOver(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDragOver(false);
          if (e.dataTransfer.files.length) loadFiles(e.dataTransfer.files);
        }}
      >
        {loading ? 'Parsing…' : 'Drop .fcs files here, or click to browse'}
        <input
          ref={inputRef}
          type="file"
          accept=".fcs"
          multiple
          hidden
          onChange={(e) => {
            if (e.target.files?.length) loadFiles(e.target.files);
            e.target.value = '';
          }}
        />
      </div>
      {DROPBOX_APP_KEY && (
        <button className="btn btn-cloud-import" onClick={handleImportFromDropbox} disabled={dropboxBusy}>
          {dropboxBusy ? 'Importing…' : 'Import from Dropbox…'}
        </button>
      )}
      {dropboxError && (
        <div className="error-banner">
          <pre>{dropboxError}</pre>
          <button className="btn" onClick={() => setDropboxError(null)}>
            Dismiss
          </button>
        </div>
      )}
      {error && (
        <div className="error-banner">
          <pre>{error}</pre>
          <button className="btn" onClick={clearError}>
            Dismiss
          </button>
        </div>
      )}
    </div>
  );
}
