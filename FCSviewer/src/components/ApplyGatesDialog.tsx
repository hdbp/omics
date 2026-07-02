import { useState } from 'react';
import type { Sample } from '../state/types';

interface Props {
  source: Sample;
  otherSamples: Sample[];
  onConfirm: (targetIds: string[]) => void;
  onCancel: () => void;
}

export function ApplyGatesDialog({ source, otherSamples, onConfirm, onCancel }: Props) {
  const [selected, setSelected] = useState<Set<string>>(new Set(otherSamples.map((s) => s.id)));

  function toggle(id: string) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  return (
    <div className="modal-backdrop" onClick={onCancel}>
      <div className="modal modal-wide" onClick={(e) => e.stopPropagation()}>
        <h3>Apply gating strategy from "{source.fileName}"</h3>
        {otherSamples.length === 0 ? (
          <p className="modal-empty">No other samples are loaded yet. Load more .fcs files first.</p>
        ) : (
          <ul className="apply-gates-list">
            {otherSamples.map((s) => (
              <li key={s.id}>
                <label>
                  <input type="checkbox" checked={selected.has(s.id)} onChange={() => toggle(s.id)} />
                  {s.fileName}
                </label>
              </li>
            ))}
          </ul>
        )}
        <p className="modal-note">
          Gates whose parameters aren't present in a target sample will be skipped for that sample.
          This replaces each target's existing gates.
        </p>
        <div className="modal-actions">
          <button className="btn" onClick={onCancel}>
            Cancel
          </button>
          <button
            className="btn btn-primary"
            disabled={selected.size === 0}
            onClick={() => onConfirm([...selected])}
          >
            Apply to {selected.size} sample{selected.size === 1 ? '' : 's'}
          </button>
        </div>
      </div>
    </div>
  );
}
