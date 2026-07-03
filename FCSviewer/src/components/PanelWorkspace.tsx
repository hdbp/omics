import { useEffect, useMemo, useState } from 'react';
import { useStore } from '../state/store';
import type { Sample } from '../state/types';
import { ancestorChain } from '../gating/gateEval';
import { GatePanel } from './GatePanel';
import { PADDING, MIN_PANEL_WIDTH, MIN_PANEL_HEIGHT } from '../state/panelLayout';
import { downloadCanvasAsPng, truncateText } from '../utils/exportImage';
import { drawPlotPanel } from '../utils/plotRender';
import { getExportTheme, type ExportThemeName } from '../utils/theme';

const EXPORT_HEADER_HEIGHT = 42;

interface DragState {
  panelId: string;
  startX: number;
  startY: number;
  origX: number;
  origY: number;
}

interface ResizeState {
  panelId: string;
  startX: number;
  startY: number;
  origWidth: number;
  origHeight: number;
}

export function PanelWorkspace({ sample }: { sample: Sample }) {
  const { movePanel, resizePanel, autoArrangePanels, focusedPanelId, focusPanel } = useStore();
  const [dragState, setDragState] = useState<DragState | null>(null);
  const [resizeState, setResizeState] = useState<ResizeState | null>(null);
  const [exportTheme, setExportTheme] = useState<ExportThemeName>('light');

  useEffect(() => {
    if (!focusedPanelId) return;
    const t = setTimeout(() => focusPanel(null), 1400);
    return () => clearTimeout(t);
  }, [focusedPanelId, focusPanel]);

  useEffect(() => {
    if (!dragState) return;
    function onMove(e: MouseEvent) {
      if (!dragState) return;
      const dx = e.clientX - dragState.startX;
      const dy = e.clientY - dragState.startY;
      movePanel(sample.id, dragState.panelId, Math.max(0, dragState.origX + dx), Math.max(0, dragState.origY + dy));
    }
    function onUp() {
      setDragState(null);
    }
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
    return () => {
      window.removeEventListener('mousemove', onMove);
      window.removeEventListener('mouseup', onUp);
    };
  }, [dragState, sample.id, movePanel]);

  useEffect(() => {
    if (!resizeState) return;
    function onMove(e: MouseEvent) {
      if (!resizeState) return;
      const dx = e.clientX - resizeState.startX;
      const dy = e.clientY - resizeState.startY;
      resizePanel(
        sample.id,
        resizeState.panelId,
        Math.max(MIN_PANEL_WIDTH, resizeState.origWidth + dx),
        Math.max(MIN_PANEL_HEIGHT, resizeState.origHeight + dy)
      );
    }
    function onUp() {
      setResizeState(null);
    }
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
    return () => {
      window.removeEventListener('mousemove', onMove);
      window.removeEventListener('mouseup', onUp);
    };
  }, [resizeState, sample.id, resizePanel]);

  const contentSize = useMemo(() => {
    const maxX = sample.panels.reduce((m, p) => Math.max(m, p.x + p.width), 0) + PADDING;
    const maxY = sample.panels.reduce((m, p) => Math.max(m, p.y + p.height), 0) + PADDING;
    return { width: maxX, height: maxY };
  }, [sample.panels]);

  const connectors = useMemo(() => {
    const lines: { x1: number; y1: number; x2: number; y2: number; key: string }[] = [];
    for (const p of sample.panels) {
      if (!p.parentPanelId) continue;
      const parent = sample.panels.find((pp) => pp.id === p.parentPanelId);
      if (!parent) continue;
      lines.push({
        x1: parent.x + parent.width,
        y1: parent.y + parent.height / 2,
        x2: p.x,
        y2: p.y + p.height / 2,
        key: `${parent.id}-${p.id}`,
      });
    }
    return lines;
  }, [sample.panels]);

  function exportLayout() {
    const panels = sample.panels;
    if (panels.length === 0) return;
    const theme = getExportTheme(exportTheme);
    const scale = 2;
    const out = document.createElement('canvas');
    out.width = contentSize.width * scale;
    out.height = contentSize.height * scale;
    const ctx = out.getContext('2d');
    if (!ctx) return;
    ctx.scale(scale, scale);
    ctx.fillStyle = theme.pageBg;
    ctx.fillRect(0, 0, contentSize.width, contentSize.height);

    ctx.strokeStyle = theme.connectorStroke;
    ctx.lineWidth = 1.5;
    for (const line of connectors) {
      ctx.beginPath();
      ctx.moveTo(line.x1, line.y1);
      ctx.bezierCurveTo(line.x1 + 40, line.y1, line.x2 - 40, line.y2, line.x2, line.y2);
      ctx.stroke();
    }

    for (const p of panels) {
      ctx.fillStyle = theme.panelBg;
      ctx.strokeStyle = theme.panelBorder;
      ctx.lineWidth = 1;
      if (typeof ctx.roundRect === 'function') {
        ctx.beginPath();
        ctx.roundRect(p.x, p.y, p.width, p.height, 8);
        ctx.fill();
        ctx.stroke();
      } else {
        ctx.fillRect(p.x, p.y, p.width, p.height);
        ctx.strokeRect(p.x, p.y, p.width, p.height);
      }

      const gateName = sample.gates[p.gateId]?.name ?? 'Population';
      const pathStr = ancestorChain(sample.gates, p.gateId)
        .map((n) => n.name)
        .join(' › ');
      ctx.fillStyle = theme.titleText;
      ctx.font = 'bold 13px system-ui, sans-serif';
      ctx.textAlign = 'left';
      ctx.fillText(truncateText(gateName, 40), p.x + 12, p.y + 22);
      ctx.fillStyle = theme.subtitleText;
      ctx.font = '10px system-ui, sans-serif';
      ctx.fillText(truncateText(pathStr, 48), p.x + 12, p.y + 36);

      drawPlotPanel(ctx, p.x, p.y + EXPORT_HEADER_HEIGHT, p.width, p.height - EXPORT_HEADER_HEIGHT, { sample, ...p }, theme);
    }

    downloadCanvasAsPng(out, `${sample.fileName.replace(/\.fcs$/i, '')}_gating_layout.png`);
  }

  return (
    <div className="panel-workspace-wrap">
      <div className="panel-workspace-toolbar">
        <span className="workspace-title">
          {sample.fileName} · {sample.panels.length} panel{sample.panels.length === 1 ? '' : 's'}
        </span>
        <div className="btn-group">
          <button className="btn" onClick={() => autoArrangePanels(sample.id)}>
            Auto-arrange
          </button>
        </div>
        <div className="export-theme-group" title="Background for the exported PNG">
          <button className={`btn btn-small ${exportTheme === 'light' ? 'btn-active' : ''}`} onClick={() => setExportTheme('light')}>
            Light bg
          </button>
          <button className={`btn btn-small ${exportTheme === 'dark' ? 'btn-active' : ''}`} onClick={() => setExportTheme('dark')}>
            Dark bg
          </button>
        </div>
        <div className="btn-group">
          <button className="btn btn-primary" onClick={exportLayout}>
            Export layout as PNG
          </button>
        </div>
      </div>
      <div className="panel-workspace-scroll">
        <div className="panel-workspace-canvas" style={{ width: contentSize.width, height: contentSize.height }}>
          <svg className="panel-connectors" width={contentSize.width} height={contentSize.height}>
            {connectors.map((line) => (
              <path
                key={line.key}
                d={`M ${line.x1} ${line.y1} C ${line.x1 + 40} ${line.y1}, ${line.x2 - 40} ${line.y2}, ${line.x2} ${line.y2}`}
                fill="none"
                stroke="#4b5160"
                strokeWidth={1.5}
              />
            ))}
          </svg>
          {sample.panels.map((panel) => (
            <GatePanel
              key={panel.id}
              sample={sample}
              panel={panel}
              isFocused={panel.id === focusedPanelId}
              onDragHandleDown={(e) =>
                setDragState({ panelId: panel.id, startX: e.clientX, startY: e.clientY, origX: panel.x, origY: panel.y })
              }
              onResizeHandleDown={(e) => {
                e.preventDefault();
                e.stopPropagation();
                setResizeState({
                  panelId: panel.id,
                  startX: e.clientX,
                  startY: e.clientY,
                  origWidth: panel.width,
                  origHeight: panel.height,
                });
              }}
            />
          ))}
        </div>
      </div>
    </div>
  );
}
