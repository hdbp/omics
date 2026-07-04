import type { Sample, LayoutItem } from '../state/types';

const MAGIC = 'FCSVPROJ';
const FORMAT_VERSION = 1;
/** magic (8 bytes) + format version (u32) + metadata length (u32) */
const HEADER_BYTES = 8 + 4 + 4;

type SampleMeta = Omit<Sample, 'data'>;

interface ProjectMeta {
  format: string;
  version: number;
  savedAt: string;
  activeSampleId: string | null;
  mainView: 'samples' | 'layout' | 'notebook';
  layoutItems: LayoutItem[];
  samples: SampleMeta[];
  /** Free-text assay/experiment notes. Optional on read since older project files predate this field. */
  notebookText?: string;
}

export interface ProjectState {
  samples: Sample[];
  layoutItems: LayoutItem[];
  activeSampleId: string | null;
  mainView: 'samples' | 'layout' | 'notebook';
  notebookText: string;
}

export class ProjectFileError extends Error {}

function align4(n: number): number {
  return (n + 3) & ~3;
}

/**
 * Serializes the whole workspace — every loaded sample's parameters/gates/panels
 * (and its raw event data) plus the Layout collage — into a single downloadable
 * file: a JSON metadata header followed by the event data as raw float32 columns
 * (sample order, then parameter order), so re-opening it resumes exactly where
 * you left off without needing the original .fcs files again.
 */
export function serializeProject(state: ProjectState): Blob {
  const meta: ProjectMeta = {
    format: MAGIC,
    version: FORMAT_VERSION,
    savedAt: new Date().toISOString(),
    activeSampleId: state.activeSampleId,
    mainView: state.mainView,
    notebookText: state.notebookText,
    layoutItems: state.layoutItems,
    samples: state.samples.map(({ data: _data, ...rest }) => rest),
  };
  const metaBytes = new TextEncoder().encode(JSON.stringify(meta));

  const unpaddedLength = HEADER_BYTES + metaBytes.byteLength;
  const padding = new Uint8Array(align4(unpaddedLength) - unpaddedLength);

  const header = new ArrayBuffer(HEADER_BYTES);
  const headerView = new DataView(header);
  for (let i = 0; i < MAGIC.length; i++) headerView.setUint8(i, MAGIC.charCodeAt(i));
  headerView.setUint32(8, FORMAT_VERSION, true);
  headerView.setUint32(12, metaBytes.byteLength, true);

  const dataParts: BlobPart[] = [];
  for (const sample of state.samples) {
    for (const column of sample.data) {
      dataParts.push((column.buffer as ArrayBuffer).slice(column.byteOffset, column.byteOffset + column.byteLength));
    }
  }

  return new Blob([header, metaBytes, padding, ...dataParts], { type: 'application/octet-stream' });
}

/** Parses a file written by serializeProject() back into loadable app state. Throws ProjectFileError on anything malformed. */
export async function deserializeProject(file: Blob): Promise<ProjectState> {
  const buf = await file.arrayBuffer();
  if (buf.byteLength < HEADER_BYTES) {
    throw new ProjectFileError('This file is too small to be a valid FCS Viewer project file.');
  }
  const bytes = new Uint8Array(buf);
  const magic = String.fromCharCode(...bytes.subarray(0, MAGIC.length));
  if (magic !== MAGIC) {
    throw new ProjectFileError('This is not an FCS Viewer project file (.fcsproj).');
  }

  const headerView = new DataView(buf);
  const version = headerView.getUint32(8, true);
  if (version !== FORMAT_VERSION) {
    throw new ProjectFileError(`This project file uses an unsupported format version (${version}).`);
  }
  const metaLength = headerView.getUint32(12, true);
  if (HEADER_BYTES + metaLength > buf.byteLength) {
    throw new ProjectFileError('This project file is corrupted (metadata is truncated).');
  }

  let meta: ProjectMeta;
  try {
    const metaBytes = new Uint8Array(buf, HEADER_BYTES, metaLength);
    meta = JSON.parse(new TextDecoder().decode(metaBytes));
  } catch {
    throw new ProjectFileError('This project file is corrupted (could not parse its metadata).');
  }

  let offset = align4(HEADER_BYTES + metaLength);
  const samples: Sample[] = meta.samples.map((sm) => {
    const data: Float32Array[] = sm.parameters.map(() => {
      const byteLength = sm.eventCount * Float32Array.BYTES_PER_ELEMENT;
      if (offset + byteLength > buf.byteLength) {
        throw new ProjectFileError('This project file is corrupted (event data is truncated).');
      }
      const column = new Float32Array(buf, offset, sm.eventCount);
      offset += byteLength;
      return column;
    });
    return { ...sm, data };
  });

  return {
    samples,
    layoutItems: meta.layoutItems,
    activeSampleId: meta.activeSampleId,
    mainView: meta.mainView,
    notebookText: meta.notebookText ?? '',
  };
}
