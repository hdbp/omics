import { useEffect, useMemo, useRef, useState } from 'react';
import { useStore } from '../state/store';
import { ancestorChain } from '../gating/gateEval';
import { computeLayoutItemStats, formatStatsField } from '../gating/gateStats';
import { LayoutPanel } from './LayoutPanel';
import { PADDING, MIN_PANEL_WIDTH, MIN_PANEL_HEIGHT } from '../state/panelLayout';
import { downloadCanvasAsPng, truncateText } from '../utils/exportImage';
import { downloadCsv } from '../utils/csv';
import { DEFAULT_STATS_FIELDS, STATS_FIELD_LABELS, type LayoutItem } from '../state/types';

const SNAP_THRESHOLD = 6;
const MOVE_THRESHOLD = 3;

interface DragState {
  itemId: string;
  startX: number;
  startY: number;
  origX: number;
  origY: number;
  shiftKey: boolean;
}

interface ResizeState {
  itemId: string;
  startX: number;
  startY: number;
  origWidth: number;
  origHeight: number;
}

interface Guides {
  x?: number;
  y?: number;
}

/** Snaps a dragged item's position to nearby items' edges/centers within SNAP_THRESHOLD, for alignment guides. */
function computeSnappedPosition(
  draggedId: string,
  rawX: number,
  rawY: number,
  width: number,
  height: number,
  allItems: LayoutItem[]
): { x: number; y: number; guideX?: number; guideY?: number } {
  let x = rawX;
  let y = rawY;
  let guideX: number | undefined;
  let guideY: number | undefined;
  for (const other of allItems) {
    if (other.id === draggedId) continue;
    const xTargets = [other.x, other.x + other.width, other.x + other.width / 2];
    const xCandidates: [number, number][] = [
      [x, 0],
      [x + width, width],
      [x + width / 2, width / 2],
    ];
    for (const target of xTargets) {
      for (const [candidate, offset] of xCandidates) {
        if (Math.abs(candidate - target) <= SNAP_THRESHOLD) {
          x = target - offset;
          guideX = target;
        }
      }
    }
    const yTargets = [other.y, other.y + other.height, other.y + other.height / 2];
    const yCandidates: [number, number][] = [
      [y, 0],
      [y + height, height],
      [y + height / 2, height / 2],
    ];
    for (const target of yTargets) {
      for (const [candidate, offset] of yCandidates) {
        if (Math.abs(candidate - target) <= SNAP_THRESHOLD) {
          y = target - offset;
          guideY = target;
        }
      }
    }
  }
  return { x: Math.max(0, x), y: Math.max(0, y), guideX, guideY };
}

/**
 * The cross-sample "Layout" collage: a curated canvas of panels pulled from
 * any sample's workspace, arranged and labeled independently for a
 * publish-quality figure export. No hierarchy between items (unlike
 * PanelWorkspace), so no connector lines — just a free arrangement, with
 * multi-select + align/distribute helpers and drag-snap guides.
 */
export function LayoutWorkspace() {
  const { samples, layoutItems, moveLayoutItem, resizeLayoutItem, autoArrangeLayout, focusedLayoutItemId, focusLayoutItem } =
    useStore();
  const canvasRefs = useRef(new Map<string, HTMLCanvasElement>());
  const rootRefs = useRef(new Map<string, HTMLDivElement>());
  const [dragState, setDragState] = useState<DragState | null>(null);
  const [resizeState, setResizeState] = useState<ResizeState | null>(null);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [guides, setGuides] = useState<Guides>({});
  const movedRef = useRef(false);

  useEffect(() => {
    if (!focusedLayoutItemId) return;
    const t = setTimeout(() => focusLayoutItem(null), 1400);
    return () => clearTimeout(t);
  }, [focusedLayoutItemId, focusLayoutItem]);

  useEffect(() => {
    if (!dragState) return;
    movedRef.current = false;
    function onMove(e: MouseEvent) {
      if (!dragState) return;
      const dx = e.clientX - dragState.startX;
      const dy = e.clientY - dragState.startY;
      if (!movedRef.current && Math.hypot(dx, dy) < MOVE_THRESHOLD) return;
      movedRef.current = true;

      const allItems = useStore.getState().layoutItems;
      const dragged = allItems.find((it) => it.id === dragState.itemId);
      if (!dragged) return;
      const rawX = Math.max(0, dragState.origX + dx);
      const rawY = Math.max(0, dragState.origY + dy);
      const snapped = computeSnappedPosition(dragState.itemId, rawX, rawY, dragged.width, dragged.height, allItems);
      setGuides({ x: snapped.guideX, y: snapped.guideY });
      moveLayoutItem(dragState.itemId, snapped.x, snapped.y);
    }
    function onUp() {
      if (!dragState) return;
      const { itemId, shiftKey } = dragState;
      if (!movedRef.current) {
        setSelectedIds((sel) => {
          const next = new Set(shiftKey ? sel : []);
          if (next.has(itemId)) next.delete(itemId);
          else next.add(itemId);
          return next;
        });
      }
      setGuides({});
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

  function alignSelected(edge: 'left' | 'right' | 'top' | 'bottom' | 'centerX' | 'centerY') {
    const items = layoutItems.filter((it) => selectedIds.has(it.id));
    if (items.length < 2) return;
    if (edge === 'left') {
      const v = Math.min(...items.map((it) => it.x));
      items.forEach((it) => moveLayoutItem(it.id, v, it.y));
    } else if (edge === 'right') {
      const v = Math.max(...items.map((it) => it.x + it.width));
      items.forEach((it) => moveLayoutItem(it.id, v - it.width, it.y));
    } else if (edge === 'top') {
      const v = Math.min(...items.map((it) => it.y));
      items.forEach((it) => moveLayoutItem(it.id, it.x, v));
    } else if (edge === 'bottom') {
      const v = Math.max(...items.map((it) => it.y + it.height));
      items.forEach((it) => moveLayoutItem(it.id, it.x, v - it.height));
    } else if (edge === 'centerX') {
      const avg = items.reduce((sum, it) => sum + it.x + it.width / 2, 0) / items.length;
      items.forEach((it) => moveLayoutItem(it.id, avg - it.width / 2, it.y));
    } else if (edge === 'centerY') {
      const avg = items.reduce((sum, it) => sum + it.y + it.height / 2, 0) / items.length;
      items.forEach((it) => moveLayoutItem(it.id, it.x, avg - it.height / 2));
    }
  }

  function distributeSelected(axis: 'x' | 'y') {
    const items = layoutItems.filter((it) => selectedIds.has(it.id));
    if (items.length < 3) return;
    if (axis === 'x') {
      const sorted = [...items].sort((a, b) => a.x - b.x);
      const first = sorted[0];
      const last = sorted[sorted.length - 1];
      const totalSpan = last.x + last.width - first.x;
      const totalWidth = sorted.reduce((sum, it) => sum + it.width, 0);
      const gap = (totalSpan - totalWidth) / (sorted.length - 1);
      let cursor = first.x;
      for (const it of sorted) {
        moveLayoutItem(it.id, cursor, it.y);
        cursor += it.width + gap;
      }
    } else {
      const sorted = [...items].sort((a, b) => a.y - b.y);
      const first = sorted[0];
      const last = sorted[sorted.length - 1];
      const totalSpan = last.y + last.height - first.y;
      const totalHeight = sorted.reduce((sum, it) => sum + it.height, 0);
      const gap = (totalSpan - totalHeight) / (sorted.length - 1);
      let cursor = first.y;
      for (const it of sorted) {
        moveLayoutItem(it.id, it.x, cursor);
        cursor += it.height + gap;
      }
    }
  }

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

      const statsFields = item.statsFields ?? DEFAULT_STATS_FIELDS;
      if (sample && statsFields.length > 0) {
        const stats = computeLayoutItemStats(sample, item.gateId, item.xParam, item.yParam, item.plotType);
        const text = statsFields.map((k) => `${STATS_FIELD_LABELS[k]}: ${formatStatsField(k, stats, item.plotType)}`).join('   ·   ');
        ctx.fillStyle = '#9aa4b2';
        ctx.font = '9px system-ui, sans-serif';
        ctx.textAlign = 'left';
        ctx.fillText(truncateText(text, Math.floor(item.width / 4.2)), item.x + 12, item.y + item.height - 8);
      }
    }

    downloadCanvasAsPng(out, 'fcs_layout_figure.png');
  }

  function exportStats() {
    if (layoutItems.length === 0) return;
    const header = ['Label', 'Sample', 'Population', 'Count', '% Parent', '% Total', 'X Parameter', 'Median X', 'Y Parameter', 'Median Y'];
    const rows: (string | number)[][] = [header];
    for (const item of layoutItems) {
      const sample = samples.find((s) => s.id === item.sampleId);
      if (!sample) {
        rows.push([item.label, '(sample removed)', '', '', '', '', item.xParam, '', item.yParam, '']);
        continue;
      }
      const stats = computeLayoutItemStats(sample, item.gateId, item.xParam, item.yParam, item.plotType);
      rows.push([
        item.label,
        sample.fileName,
        stats.populationPath,
        stats.count,
        stats.percentParent.toFixed(2),
        stats.percentTotal.toFixed(2),
        item.xAxisLabel || item.xParam,
        Number.isFinite(stats.medianX) ? stats.medianX.toFixed(1) : '',
        item.plotType === 'scatter' ? item.yAxisLabel || item.yParam : '',
        Number.isFinite(stats.medianY) ? stats.medianY.toFixed(1) : '',
      ]);
    }
    downloadCsv('fcs_layout_stats.csv', rows);
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
          <button className="btn" onClick={exportStats} disabled={layoutItems.length === 0}>
            Export stats CSV
          </button>
          <button className="btn btn-primary" onClick={exportLayout} disabled={layoutItems.length === 0}>
            Export layout as PNG
          </button>
        </div>
        {selectedIds.size >= 2 && (
          <div className="layout-align-group">
            <span className="workspace-title">{selectedIds.size} selected:</span>
            <button className="btn btn-small" title="Align left edges" onClick={() => alignSelected('left')}>
              Left
            </button>
            <button className="btn btn-small" title="Align right edges" onClick={() => alignSelected('right')}>
              Right
            </button>
            <button className="btn btn-small" title="Align top edges" onClick={() => alignSelected('top')}>
              Top
            </button>
            <button className="btn btn-small" title="Align bottom edges" onClick={() => alignSelected('bottom')}>
              Bottom
            </button>
            <button className="btn btn-small" title="Align horizontal centers" onClick={() => alignSelected('centerX')}>
              Ctr X
            </button>
            <button className="btn btn-small" title="Align vertical centers" onClick={() => alignSelected('centerY')}>
              Ctr Y
            </button>
            <button
              className="btn btn-small"
              title="Distribute evenly left-to-right"
              disabled={selectedIds.size < 3}
              onClick={() => distributeSelected('x')}
            >
              Dist X
            </button>
            <button
              className="btn btn-small"
              title="Distribute evenly top-to-bottom"
              disabled={selectedIds.size < 3}
              onClick={() => distributeSelected('y')}
            >
              Dist Y
            </button>
            <button className="btn btn-small" title="Clear selection" onClick={() => setSelectedIds(new Set())}>
              ×
            </button>
          </div>
        )}
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
          <div
            className="panel-workspace-canvas"
            style={{ width: contentSize.width, height: contentSize.height }}
            onClick={(e) => {
              if (e.target === e.currentTarget) setSelectedIds(new Set());
            }}
          >
            {(guides.x !== undefined || guides.y !== undefined) && (
              <svg className="panel-connectors" width={contentSize.width} height={contentSize.height}>
                {guides.x !== undefined && (
                  <line className="layout-guide-line" x1={guides.x} y1={0} x2={guides.x} y2={contentSize.height} />
                )}
                {guides.y !== undefined && (
                  <line className="layout-guide-line" x1={0} y1={guides.y} x2={contentSize.width} y2={guides.y} />
                )}
              </svg>
            )}
            {layoutItems.map((item) => (
              <LayoutPanel
                key={item.id}
                item={item}
                sample={samples.find((s) => s.id === item.sampleId)}
                isFocused={item.id === focusedLayoutItemId}
                isSelected={selectedIds.has(item.id)}
                onDragHandleDown={(e) =>
                  setDragState({
                    itemId: item.id,
                    startX: e.clientX,
                    startY: e.clientY,
                    origX: item.x,
                    origY: item.y,
                    shiftKey: e.shiftKey,
                  })
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
