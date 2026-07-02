import { useRef, useState } from 'react';
import { useStore } from '../state/store';

export function FileLoader() {
  const { loadFiles, loading, error, clearError } = useStore();
  const inputRef = useRef<HTMLInputElement>(null);
  const [dragOver, setDragOver] = useState(false);

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
