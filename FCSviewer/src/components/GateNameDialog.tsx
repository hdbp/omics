import { useState } from 'react';

interface Props {
  defaultName: string;
  onConfirm: (name: string) => void;
  onCancel: () => void;
}

export function GateNameDialog({ defaultName, onConfirm, onCancel }: Props) {
  const [name, setName] = useState(defaultName);

  return (
    <div className="modal-backdrop" onClick={onCancel}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h3>Name gate</h3>
        <input
          autoFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && name.trim()) onConfirm(name.trim());
            if (e.key === 'Escape') onCancel();
          }}
        />
        <div className="modal-actions">
          <button className="btn" onClick={onCancel}>
            Cancel
          </button>
          <button className="btn btn-primary" disabled={!name.trim()} onClick={() => onConfirm(name.trim())}>
            Create gate
          </button>
        </div>
      </div>
    </div>
  );
}
