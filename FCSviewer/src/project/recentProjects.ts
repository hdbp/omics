import type { ProjectState } from './projectFile';

const DB_NAME = 'fcsviewer-recent-projects';
const DB_VERSION = 1;
const META_STORE = 'meta';
const DATA_STORE = 'data';

/** Capped since each entry can carry a full copy of every sample's event data (Float32Array columns). */
export const MAX_RECENT_PROJECTS = 6;

export interface RecentProjectMeta {
  id: string;
  name: string;
  savedAt: string;
  sampleFileNames: string[];
  totalEvents: number;
}

export function recentProjectsSupported(): boolean {
  return typeof indexedDB !== 'undefined';
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(META_STORE)) db.createObjectStore(META_STORE, { keyPath: 'id' });
      if (!db.objectStoreNames.contains(DATA_STORE)) db.createObjectStore(DATA_STORE, { keyPath: 'id' });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function reqToPromise<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function txDone(t: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    t.oncomplete = () => resolve();
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error);
  });
}

/** Sanitized project name doubles as its recent-entry id, so re-saving/re-opening the same name updates one slot instead of piling up duplicates. */
export function sanitizeProjectName(name: string): string {
  return name.trim().replace(/[\\/:*?"<>|]+/g, '_').slice(0, 120) || 'Untitled project';
}

export async function listRecentProjects(): Promise<RecentProjectMeta[]> {
  const db = await openDb();
  try {
    const store = db.transaction([META_STORE], 'readonly').objectStore(META_STORE);
    const all = await reqToPromise(store.getAll() as IDBRequest<RecentProjectMeta[]>);
    return all.sort((a, b) => b.savedAt.localeCompare(a.savedAt));
  } finally {
    db.close();
  }
}

export async function saveRecentProject(name: string, state: ProjectState): Promise<void> {
  const id = sanitizeProjectName(name);
  const meta: RecentProjectMeta = {
    id,
    name: id,
    savedAt: new Date().toISOString(),
    sampleFileNames: state.samples.map((s) => s.fileName),
    totalEvents: state.samples.reduce((sum, s) => sum + s.eventCount, 0),
  };
  const db = await openDb();
  try {
    const t = db.transaction([META_STORE, DATA_STORE], 'readwrite');
    t.objectStore(META_STORE).put(meta);
    t.objectStore(DATA_STORE).put({ id, state });
    await txDone(t);
  } finally {
    db.close();
  }

  const all = await listRecentProjects();
  if (all.length > MAX_RECENT_PROJECTS) {
    const stale = all.slice(MAX_RECENT_PROJECTS);
    const db2 = await openDb();
    try {
      const t2 = db2.transaction([META_STORE, DATA_STORE], 'readwrite');
      for (const entry of stale) {
        t2.objectStore(META_STORE).delete(entry.id);
        t2.objectStore(DATA_STORE).delete(entry.id);
      }
      await txDone(t2);
    } finally {
      db2.close();
    }
  }
}

export async function loadRecentProject(id: string): Promise<ProjectState> {
  const db = await openDb();
  try {
    const store = db.transaction([DATA_STORE], 'readonly').objectStore(DATA_STORE);
    const record = await reqToPromise(store.get(id) as IDBRequest<{ id: string; state: ProjectState } | undefined>);
    if (!record) throw new Error('This recent project is no longer available (it may have been cleared).');
    return record.state;
  } finally {
    db.close();
  }
}

export async function removeRecentProject(id: string): Promise<void> {
  const db = await openDb();
  try {
    const t = db.transaction([META_STORE, DATA_STORE], 'readwrite');
    t.objectStore(META_STORE).delete(id);
    t.objectStore(DATA_STORE).delete(id);
    await txDone(t);
  } finally {
    db.close();
  }
}

export async function clearRecentProjects(): Promise<void> {
  const db = await openDb();
  try {
    const t = db.transaction([META_STORE, DATA_STORE], 'readwrite');
    t.objectStore(META_STORE).clear();
    t.objectStore(DATA_STORE).clear();
    await txDone(t);
  } finally {
    db.close();
  }
}
