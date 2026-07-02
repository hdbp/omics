import { useState } from 'react';
import { useStore } from '../state/store';
import type { Sample } from '../state/types';
import { ROOT_GATE_ID } from '../gating/gateTypes';
import type { GateStat } from '../gating/gateStats';
import { ApplyGatesDialog } from './ApplyGatesDialog';

export function GateTree({ sample, stats }: { sample: Sample; stats: GateStat[] }) {
  const { samples, selectGate, renameGate, deleteGate, applyGatingStrategy } = useStore();
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editValue, setEditValue] = useState('');
  const [applyDialogOpen, setApplyDialogOpen] = useState(false);

  const hasGates = sample.gates[ROOT_GATE_ID]?.childIds.length > 0;
  const otherSamples = samples.filter((s) => s.id !== sample.id);

  return (
    <div className="gate-tree">
      <div className="panel-title-row">
        <div className="panel-title">Gating hierarchy</div>
        {hasGates && (
          <button className="btn btn-small" onClick={() => setApplyDialogOpen(true)}>
            Apply to other samples…
          </button>
        )}
      </div>
      <ul className="gate-list">
        {stats.map((s) => (
          <li
            key={s.gateId}
            className={`gate-item ${s.gateId === sample.activeGateId ? 'gate-item-active' : ''}`}
            style={{ paddingLeft: 8 + s.depth * 16 }}
          >
            {editingId === s.gateId ? (
              <input
                autoFocus
                className="gate-rename-input"
                value={editValue}
                onChange={(e) => setEditValue(e.target.value)}
                onBlur={() => {
                  if (editValue.trim()) renameGate(sample.id, s.gateId, editValue.trim());
                  setEditingId(null);
                }}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    if (editValue.trim()) renameGate(sample.id, s.gateId, editValue.trim());
                    setEditingId(null);
                  }
                  if (e.key === 'Escape') setEditingId(null);
                }}
              />
            ) : (
              <span
                className="gate-name"
                onClick={() => selectGate(sample.id, s.gateId)}
                onDoubleClick={() => {
                  if (s.gateId === ROOT_GATE_ID) return;
                  setEditingId(s.gateId);
                  setEditValue(s.name);
                }}
                title="Click to view · double-click to rename"
              >
                {s.name}
              </span>
            )}
            <span className="gate-count">
              {s.count.toLocaleString()} ({s.percentParent.toFixed(1)}%)
            </span>
            {s.gateId !== ROOT_GATE_ID && (
              <button
                className="gate-delete"
                title="Delete gate"
                onClick={(e) => {
                  e.stopPropagation();
                  deleteGate(sample.id, s.gateId);
                }}
              >
                ×
              </button>
            )}
          </li>
        ))}
      </ul>
      {applyDialogOpen && (
        <ApplyGatesDialog
          source={sample}
          otherSamples={otherSamples}
          onCancel={() => setApplyDialogOpen(false)}
          onConfirm={(targetIds) => {
            applyGatingStrategy(sample.id, targetIds);
            setApplyDialogOpen(false);
          }}
        />
      )}
    </div>
  );
}
