import { useEffect, useMemo, useRef, useState } from 'react';
import { useStore } from '../state/store';
import { ancestorChain } from '../gating/gateEval';
import { LayoutPanel } from './LayoutPanel';
import { PADDING, MIN_PANEL_WIDTH, MIN_PANEL_HEIGHT } from '../state/panelLayout';
import { downloadCanvasAsPng, truncateText } from '../utils/exportImage';

interface DragState {
  itemId: string;
  startX: number;
  startY: number;
  origX: number;
  origY: number;
}

interface ResizeState {
  itemId: string;
  startX: number;
  startY: number;
  origWidth: number;
  origHeight: number;
}

/**
 * The cross-sample "Layout" collage: a curated canvas of panels pulled from
 * any sample's workspace, arranged and labeled independently for a
 * publish-quality figure export. No hierarchy between items (unlike
 * PanelWorkspace), so no connector lines — just a free/grid arrangement.
 */
export function LayoutWorkspace() {
  const { samples, layoutItems, moveLayoutItem, resizeLayoutItem, autoArrangeLayout, focusedLayoutItemId, focusLayoutItem } =
    useStore();
  const canvasRefs = useRef(new Map<string, HTMLCanvasElement>());
  const rootRefs = useRef(new Map<string, HTMLDivElement>());
  const [dragState, setDragState] = useState<DragState | null>(null);
  const [resizeState, setResizeState] = useState<ResizeState | null>(null);

  useEffect(() => {
    if (!focusedLayoutItemId) return;
    const t = setTimeout(() => focusLayoutItem(null), 1400);
    return () => clearTimeout(t);
  }, [focusedLayoutItemId, focusLayoutItem]);

  useEffect(() => {
    if (!dragState) return;
    function onMove(e: MouseEvent) {
      if (!dragState) return;
      const dx = e.clientX - dragState.startX;
      const dy = e.clientY - dragState.startY;
      moveLayoutItem(dragState.itemId, Math.max(0, dragState.origX + dx), Math.max(0, dragState.origY + dy));
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
  }, [dragState, moveLayoutItem]);

  useEffect(() => {
    if (!resizeState) return;
    function onMove(e: MouseEvent) {
      if (!resizeState) return;
      const dx = e.clientX - resizeState.startX;
      const dy = e.clientY - resizeState.startY;
      resizeLayoutItem(
        resizeState.itemId,
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
  }, [resizeState, resizeLayoutItem]);

  const contentSize = useMemo(() => {
    const maxX = layoutItems.reduce((m, it) => Math.max(m, it.x + it.width), 0) + PADDING;
    const maxY = layoutItems.reduce((m, it) => Math.max(m, it.y + it.height), 0) + PADDING;
    return { width: Math.max(maxX, 400), height: Math.max(maxY, 300) };
  }, [layoutItems]);

  function exportLayout() {
    if (layoutItems.length === 0) return;
    const scale = 2;
    const out = document.createElement('canvas');
    out.width = contentSize.width * scale;
    out.height = contentSize.height * scale;
    const ctx = out.getContext('2d');
    if (!ctx) return;
    ctx.scale(scale, scale);
    ctx.fillStyle = '#16171d';
    ctx.fillRect(0, 0, contentSize.width, contentSize.height);

    for (const item of layoutItems) {
      const sample = samples.find((s) => s.id === item.sampleId);

      ctx.fillStyle = '#1a1b22';
      ctx.strokeStyle = '#2e303a';
      ctx.lineWidth = 1;
      if (typeof ctx.roundRect === 'function') {
        ctx.beginPath();
        ctx.roundRect(item.x, item.y, item.width, item.height, 8);
        ctx.fill();
        ctx.stroke();
      } else {
        ctx.fillRect(item.x, item.y, item.width, item.height);
        ctx.strokeRect(item.x, item.y, item.width, item.height);
      }

      const pathStr = sample
        ? `${sample.fileName} · ${ancestorChain(sample.gates, item.gateId)
            .map((n) => n.name)
            .join(' › ')}`
        : 'Source sample removed';
      ctx.fillStyle = '#e5e7eb';
      ctx.font = 'bold 13px system-ui, sans-serif';
      ctx.textAlign = 'left';
      ctx.fillText(truncateText(item.label, 40), item.x + 12, item.y + 22);
      ctx.fillStyle = '#8b93a1';
      ctx.font = '10px system-ui, sans-serif';
      ctx.fillText(truncateText(pathStr, 52), item.x + 12, item.y + 36);

      const canvasEl = canvasRefs.current.get(item.id);
      const rootEl = rootRefs.current.get(item.id);
      if (canvasEl && rootEl) {
        const rootRect = rootEl.getBoundingClientRect();
        const canvasRect = canvasEl.getBoundingClientRect();
        const offX = canvasRect.left - rootRect.left;
        const offY = canvasRect.top - rootRect.top;
        ctx.drawImage(canvasEl, item.x + offX, item.y + offY, canvasRect.width, canvasRect.height);
      }
    }

    downloadCanvasAsPng(out, 'fcs_layout_figure.png');
  }

  return (
    <div className="panel-workspace-wrap">
      <div className="panel-workspace-toolbar">
        <span className="workspace-title">
          Layout · {layoutItems.length} panel{layoutItems.length === 1 ? '' : 's'}
        </span>
        <div className="btn-group">
          <button className="btn" onClick={autoArrangeLayout} disabled={layoutItems.length === 0}>
            Auto-arrange
          </button>
          <button className="btn btn-primary" onClick={exportLayout} disabled={layoutItems.length === 0}>
            Export layout as PNG
          </button>
        </div>
      </div>
      <div className="panel-workspace-scroll">
        {layoutItems.length === 0 ? (
          <div className="layout-empty-state">
            <p>Your layout is empty.</p>
            <p className="empty-state-hint">
              Open a sample's workspace and click the <strong>⊞</strong> button in any panel's header to add it here.
            </p>
          </div>
        ) : (
          <div className="panel-workspace-canvas" style={{ width: contentSize.width, height: contentSize.height }}>
            {layoutItems.map((item) => (
              <LayoutPanel
                key={item.id}
                item={item}
                sample={samples.find((s) => s.id === item.sampleId)}
                isFocused={item.id === focusedLayoutItemId}
                onDragHandleDown={(e) =>
                  setDragState({ itemId: item.id, startX: e.clientX, startY: e.clientY, origX: item.x, origY: item.y })
                }
                onResizeHandleDown={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  setResizeState({
                    itemId: item.id,
                    startX: e.clientX,
                    startY: e.clientY,
                    origWidth: item.width,
                    origHeight: item.height,
                  });
                }}
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
        )}
      </div>
    </div>
  );
}
