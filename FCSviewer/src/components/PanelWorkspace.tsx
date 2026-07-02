import { useEffect, useMemo, useRef, useState } from 'react';
import { useStore } from '../state/store';
import type { Sample } from '../state/types';
import { ancestorChain } from '../gating/gateEval';
import { GatePanel } from './GatePanel';
import { PANEL_WIDTH, PANEL_HEIGHT, PADDING } from '../state/panelLayout';
import { downloadCanvasAsPng, truncateText } from '../utils/exportImage';

interface DragState {
  panelId: string;
  startX: number;
  startY: number;
  origX: number;
  origY: number;
}

export function PanelWorkspace({ sample }: { sample: Sample }) {
  const { movePanel, autoArrangePanels, focusedPanelId, focusPanel } = useStore();
  const canvasRefs = useRef(new Map<string, HTMLCanvasElement>());
  const rootRefs = useRef(new Map<string, HTMLDivElement>());
  const [dragState, setDragState] = useState<DragState | null>(null);

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

  const contentSize = useMemo(() => {
    const maxX = sample.panels.reduce((m, p) => Math.max(m, p.x + PANEL_WIDTH), 0) + PADDING;
    const maxY = sample.panels.reduce((m, p) => Math.max(m, p.y + PANEL_HEIGHT), 0) + PADDING;
    return { width: maxX, height: maxY };
  }, [sample.panels]);

  const connectors = useMemo(() => {
    const lines: { x1: number; y1: number; x2: number; y2: number; key: string }[] = [];
    for (const p of sample.panels) {
      if (!p.parentPanelId) continue;
      const parent = sample.panels.find((pp) => pp.id === p.parentPanelId);
      if (!parent) continue;
      lines.push({
        x1: parent.x + PANEL_WIDTH,
        y1: parent.y + PANEL_HEIGHT / 2,
        x2: p.x,
        y2: p.y + PANEL_HEIGHT / 2,
        key: `${parent.id}-${p.id}`,
      });
    }
    return lines;
  }, [sample.panels]);

  function exportLayout() {
    const panels = sample.panels;
    if (panels.length === 0) return;
    const scale = 2;
    const out = document.createElement('canvas');
    out.width = contentSize.width * scale;
    out.height = contentSize.height * scale;
    const ctx = out.getContext('2d');
    if (!ctx) return;
    ctx.scale(scale, scale);
    ctx.fillStyle = '#16171d';
    ctx.fillRect(0, 0, contentSize.width, contentSize.height);

    ctx.strokeStyle = '#4b5160';
    ctx.lineWidth = 1.5;
    for (const line of connectors) {
      ctx.beginPath();
      ctx.moveTo(line.x1, line.y1);
      ctx.bezierCurveTo(line.x1 + 40, line.y1, line.x2 - 40, line.y2, line.x2, line.y2);
      ctx.stroke();
    }

    for (const p of panels) {
      ctx.fillStyle = '#1a1b22';
      ctx.strokeStyle = '#2e303a';
      ctx.lineWidth = 1;
      if (typeof ctx.roundRect === 'function') {
        ctx.beginPath();
        ctx.roundRect(p.x, p.y, PANEL_WIDTH, PANEL_HEIGHT, 8);
        ctx.fill();
        ctx.stroke();
      } else {
        ctx.fillRect(p.x, p.y, PANEL_WIDTH, PANEL_HEIGHT);
        ctx.strokeRect(p.x, p.y, PANEL_WIDTH, PANEL_HEIGHT);
      }

      const gateName = sample.gates[p.gateId]?.name ?? 'Population';
      const pathStr = ancestorChain(sample.gates, p.gateId)
        .map((n) => n.name)
        .join(' › ');
      ctx.fillStyle = '#e5e7eb';
      ctx.font = 'bold 13px system-ui, sans-serif';
      ctx.textAlign = 'left';
      ctx.fillText(truncateText(gateName, 40), p.x + 12, p.y + 22);
      ctx.fillStyle = '#8b93a1';
      ctx.font = '10px system-ui, sans-serif';
      ctx.fillText(truncateText(pathStr, 48), p.x + 12, p.y + 36);

      const canvasEl = canvasRefs.current.get(p.id);
      const rootEl = rootRefs.current.get(p.id);
      if (canvasEl && rootEl) {
        const rootRect = rootEl.getBoundingClientRect();
        const canvasRect = canvasEl.getBoundingClientRect();
        const offX = canvasRect.left - rootRect.left;
        const offY = canvasRect.top - rootRect.top;
        ctx.drawImage(canvasEl, p.x + offX, p.y + offY, canvasRect.width, canvasRect.height);
      }
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
              onRegisterCanvas={(id, el) => {
                if (el) canvasRefs.current.set(id, el);
                else canvasRefs.current.delete(id);
              }}
              onRegisterRoot={(id, el) => {
                if (el) rootRefs.current.set(id, el);
                else rootRefs.current.delete(id);
              }}
            />
          ))}
        </div>
      </div>
    </div>
  );
}
