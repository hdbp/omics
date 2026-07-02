import { useStore } from '../state/store';

export function SampleList() {
  const { samples, activeSampleId, selectSample, removeSample } = useStore();

  if (samples.length === 0) return null;

  return (
    <div className="sample-list">
      <div className="panel-title">Samples</div>
      <ul>
        {samples.map((s) => (
          <li key={s.id} className={s.id === activeSampleId ? 'sample-item-active' : ''}>
            <span className="sample-name" onClick={() => selectSample(s.id)} title={s.fileName}>
              {s.fileName}
            </span>
            <span className="sample-meta">{s.eventCount.toLocaleString()} events</span>
            <button
              className="gate-delete"
              title="Remove sample"
              onClick={() => removeSample(s.id)}
            >
              ×
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
