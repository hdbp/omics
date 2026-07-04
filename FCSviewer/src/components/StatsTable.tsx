import { useState, type CSSProperties, type Ref } from 'react';
import { getColumn, type Sample } from '../state/types';
import type { GateStat } from '../gating/gateStats';
import { medianForParam } from '../gating/gateStats';
import { downloadCsv } from '../utils/csv';

export function StatsTable({
  sample,
  stats,
  style,
  ref,
}: {
  sample: Sample;
  stats: GateStat[];
  style?: CSSProperties;
  ref?: Ref<HTMLDivElement>;
}) {
  const [xLabel, setXLabel] = useState(sample.parameters[0]?.name ?? '');
  const [yLabel, setYLabel] = useState(sample.parameters[1]?.name ?? sample.parameters[0]?.name ?? '');

  function exportStatsCsv() {
    const header = ['Population', 'Count', '% Parent', '% Total', `Median ${xLabel}`, `Median ${yLabel}`];
    const rows: (string | number)[][] = [header];
    for (const s of stats) {
      const medX = medianForParam(sample, s.indices, xLabel);
      const medY = medianForParam(sample, s.indices, yLabel);
      rows.push([
        `${'  '.repeat(s.depth)}${s.name}`,
        s.count,
        s.percentParent.toFixed(2),
        s.percentTotal.toFixed(2),
        Number.isFinite(medX) ? medX.toFixed(1) : '',
        Number.isFinite(medY) ? medY.toFixed(1) : '',
      ]);
    }
    downloadCsv(`${sample.fileName.replace(/\.fcs$/i, '')}_gate_stats.csv`, rows);
  }

  function exportGatedEvents(stat: GateStat) {
    const header = sample.parameters.map((p) => p.name);
    const rows: (string | number)[][] = [header];
    const cols = sample.parameters.map((p) => getColumn(sample, p.name));
    for (let i = 0; i < stat.indices.length; i++) {
      const idx = stat.indices[i];
      rows.push(cols.map((c) => c[idx]));
    }
    downloadCsv(`${sample.fileName.replace(/\.fcs$/i, '')}_${stat.name}_events.csv`, rows);
  }

  const params = sample.parameters;

  return (
    <div className="stats-table-panel" style={style} ref={ref}>
      <div className="panel-title-row">
        <div className="panel-title">Statistics</div>
        <div className="stats-controls">
          <label>
            Median X:
            <select value={xLabel} onChange={(e) => setXLabel(e.target.value)}>
              {params.map((p) => (
                <option key={p.name} value={p.name}>
                  {p.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            Median Y:
            <select value={yLabel} onChange={(e) => setYLabel(e.target.value)}>
              {params.map((p) => (
                <option key={p.name} value={p.name}>
                  {p.name}
                </option>
              ))}
            </select>
          </label>
          <button className="btn" onClick={exportStatsCsv}>
            Export stats CSV
          </button>
        </div>
      </div>
      <div className="stats-table-scroll">
        <table className="stats-table">
          <thead>
            <tr>
              <th>Population</th>
              <th>Count</th>
              <th>% Parent</th>
              <th>% Total</th>
              <th>Median {xLabel}</th>
              <th>Median {yLabel}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {stats.map((s) => {
              const medX = medianForParam(sample, s.indices, xLabel);
              const medY = medianForParam(sample, s.indices, yLabel);
              return (
                <tr key={s.gateId}>
                  <td style={{ paddingLeft: 6 + s.depth * 14 }}>{s.name}</td>
                  <td>{s.count.toLocaleString()}</td>
                  <td>{s.percentParent.toFixed(1)}%</td>
                  <td>{s.percentTotal.toFixed(1)}%</td>
                  <td>{Number.isFinite(medX) ? medX.toFixed(1) : '—'}</td>
                  <td>{Number.isFinite(medY) ? medY.toFixed(1) : '—'}</td>
                  <td>
                    <button className="btn btn-small" title="Export this population's events as CSV" onClick={() => exportGatedEvents(s)}>
                      ⭳
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
