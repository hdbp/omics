import { getColumn, type Sample } from '../state/types';
import type { GateStat } from '../gating/gateStats';
import { medianForParam } from '../gating/gateStats';
import { downloadCsv } from '../utils/csv';

export function StatsTable({ sample, stats }: { sample: Sample; stats: GateStat[] }) {
  const xLabel = sample.xParam;
  const yLabel = sample.plotType === 'scatter' ? sample.yParam : null;

  function exportStatsCsv() {
    const header = ['Population', 'Count', '% Parent', '% Total', `Median ${xLabel}`];
    if (yLabel) header.push(`Median ${yLabel}`);
    const rows: (string | number)[][] = [header];
    for (const s of stats) {
      const row: (string | number)[] = [
        `${'  '.repeat(s.depth)}${s.name}`,
        s.count,
        s.percentParent.toFixed(2),
        s.percentTotal.toFixed(2),
        Number.isFinite(medianForParam(sample, s.indices, xLabel)) ? medianForParam(sample, s.indices, xLabel).toFixed(1) : '',
      ];
      if (yLabel) {
        const m = medianForParam(sample, s.indices, yLabel);
        row.push(Number.isFinite(m) ? m.toFixed(1) : '');
      }
      rows.push(row);
    }
    downloadCsv(`${sample.fileName.replace(/\.fcs$/i, '')}_gate_stats.csv`, rows);
  }

  function exportGatedEvents() {
    const activeStat = stats.find((s) => s.gateId === sample.activeGateId);
    if (!activeStat) return;
    const header = sample.parameters.map((p) => p.name);
    const rows: (string | number)[][] = [header];
    const cols = sample.parameters.map((p) => getColumn(sample, p.name));
    for (let i = 0; i < activeStat.indices.length; i++) {
      const idx = activeStat.indices[i];
      rows.push(cols.map((c) => c[idx]));
    }
    downloadCsv(`${sample.fileName.replace(/\.fcs$/i, '')}_${activeStat.name}_events.csv`, rows);
  }

  return (
    <div className="stats-table-panel">
      <div className="panel-title-row">
        <div className="panel-title">Statistics</div>
        <div className="btn-group">
          <button className="btn" onClick={exportStatsCsv}>
            Export stats CSV
          </button>
          <button className="btn" onClick={exportGatedEvents}>
            Export gated events CSV
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
              {yLabel && <th>Median {yLabel}</th>}
            </tr>
          </thead>
          <tbody>
            {stats.map((s) => {
              const medX = medianForParam(sample, s.indices, xLabel);
              const medY = yLabel ? medianForParam(sample, s.indices, yLabel) : null;
              return (
                <tr key={s.gateId} className={s.gateId === sample.activeGateId ? 'row-active' : ''}>
                  <td style={{ paddingLeft: 6 + s.depth * 14 }}>{s.name}</td>
                  <td>{s.count.toLocaleString()}</td>
                  <td>{s.percentParent.toFixed(1)}%</td>
                  <td>{s.percentTotal.toFixed(1)}%</td>
                  <td>{Number.isFinite(medX) ? medX.toFixed(1) : '—'}</td>
                  {yLabel && <td>{medY !== null && Number.isFinite(medY) ? medY.toFixed(1) : '—'}</td>}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
