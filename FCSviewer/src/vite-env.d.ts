/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Dropbox app key for the Chooser file-picker integration. Unset = the "Import from Dropbox" button is hidden. */
  readonly VITE_DROPBOX_APP_KEY?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
