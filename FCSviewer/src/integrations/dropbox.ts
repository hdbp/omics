/**
 * Dropbox "Chooser" file-picker integration: lets a user pick .fcs files
 * straight out of their own Dropbox without this app ever running a backend.
 * The Chooser handles Dropbox login/browsing in a popup and hands back a
 * short-lived direct-download link per file, which we fetch client-side and
 * feed into the same loadFiles() pipeline as drag-and-drop.
 *
 * Requires a Dropbox app key (see README) — set VITE_DROPBOX_APP_KEY in
 * FCSviewer/.env.local. Without one, callers should just not offer the button.
 */

export interface DropboxChooserFile {
  id: string;
  name: string;
  link: string;
  bytes: number;
  icon: string;
  isDir: boolean;
}

interface DropboxChooseOptions {
  success: (files: DropboxChooserFile[]) => void;
  cancel?: () => void;
  linkType: 'direct' | 'preview';
  multiselect: boolean;
  extensions?: string[];
}

declare global {
  interface Window {
    Dropbox?: {
      choose: (options: DropboxChooseOptions) => void;
    };
  }
}

const SCRIPT_ID = 'dropboxjs';
const SCRIPT_SRC = 'https://www.dropbox.com/static/api/2/dropins.js';

let loadPromise: Promise<void> | null = null;

/** Injects the Dropbox Chooser script (once) and resolves once window.Dropbox is ready. */
function loadDropboxScript(appKey: string): Promise<void> {
  if (window.Dropbox) return Promise.resolve();
  if (loadPromise) return loadPromise;

  loadPromise = new Promise((resolve, reject) => {
    const existing = document.getElementById(SCRIPT_ID);
    if (existing) {
      existing.addEventListener('load', () => resolve());
      existing.addEventListener('error', () => reject(new Error('Failed to load the Dropbox Chooser script.')));
      return;
    }
    const script = document.createElement('script');
    script.id = SCRIPT_ID;
    script.src = SCRIPT_SRC;
    script.dataset.appKey = appKey;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error('Failed to load the Dropbox Chooser script.'));
    document.body.appendChild(script);
  });
  return loadPromise;
}

/** Opens the Dropbox file picker restricted to .fcs files; resolves with the chosen files (empty array if cancelled). */
export async function chooseDropboxFiles(appKey: string): Promise<DropboxChooserFile[]> {
  await loadDropboxScript(appKey);
  if (!window.Dropbox) {
    throw new Error('Dropbox Chooser did not load. Check your network connection and try again.');
  }
  return new Promise((resolve) => {
    window.Dropbox!.choose({
      success: (files) => resolve(files),
      cancel: () => resolve([]),
      linkType: 'direct',
      multiselect: true,
      extensions: ['.fcs'],
    });
  });
}

/** Downloads a Chooser-selected file's bytes and wraps them as a File, ready for the same pipeline as drag-and-drop. */
export async function fetchDropboxFile(entry: DropboxChooserFile): Promise<File> {
  const response = await fetch(entry.link);
  if (!response.ok) {
    throw new Error(`Could not download "${entry.name}" from Dropbox (HTTP ${response.status}).`);
  }
  const blob = await response.blob();
  return new File([blob], entry.name, { type: blob.type });
}
