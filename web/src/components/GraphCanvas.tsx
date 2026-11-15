// The graph, drawn with NVL (Neo4j Visualization Library). Wire nodes and
// relationships from Relate become NVL nodes and relationships; clicks,
// double-clicks, drags, zoom and pan come from NVL's interaction handlers.

import type { NVL, Node as NvlNode, Relationship as NvlRelationship } from '@neo4j-nvl/base';
import { InteractiveNvlWrapper, type MouseEventCallbacks } from '@neo4j-nvl/react';
import { forwardRef, useEffect, useImperativeHandle, useMemo, useRef, useState } from 'react';
import type { GraphData, WireNode, WireRelationship } from '../engine/wire';
import { labelColor, labelSize, nodeCaption, primaryLabel } from '../lib/labels';

export interface GraphCanvasHandle {
  fit(): void;
  zoomBy(factor: number): void;
  savePng(filename: string): void;
}

interface Props {
  graph: GraphData;
  selectedId?: number | null;
  onSelectNode?: (node: WireNode | null) => void;
  onSelectRelationship?: (relationship: WireRelationship) => void;
  onExpandNode?: (node: WireNode) => void;
  /** Show relationship types on the edges (off for dense graphs). */
  showTypes?: boolean;
}

function useDarkMode(): boolean {
  const [dark, setDark] = useState(() => window.matchMedia('(prefers-color-scheme: dark)').matches);
  useEffect(() => {
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    const onChange = () => setDark(media.matches);
    media.addEventListener('change', onChange);
    return () => media.removeEventListener('change', onChange);
  }, []);
  return dark;
}

// Node and relationship ids are separate sequences in Relate; NVL wants one id space.
const nodeId = (id: number) => `n${id}`;
const relId = (id: number) => `r${id}`;

export const GraphCanvas = forwardRef<GraphCanvasHandle, Props>(function GraphCanvas(
  { graph, selectedId = null, onSelectNode, onSelectRelationship, onExpandNode, showTypes = true },
  ref,
) {
  const nvl = useRef<NVL>(null);
  const dark = useDarkMode();
  const [failed, setFailed] = useState<string | null>(null);
  const byId = useMemo(() => new Map(graph.nodes.map((n) => [nodeId(n.id), n])), [graph.nodes]);
  const relById = useMemo(() => new Map(graph.relationships.map((r) => [relId(r.id), r])), [graph.relationships]);

  const nodes = useMemo<NvlNode[]>(
    () =>
      graph.nodes.map((n) => {
        const label = primaryLabel(n.labels);
        return {
          id: nodeId(n.id),
          captions: [{ value: nodeCaption(n) }],
          // NVL's largest caption step: readable at the zoom a fitted graph lands on.
          captionSize: 3,
          color: labelColor(label, dark),
          size: labelSize(label),
          selected: n.id === selectedId,
        };
      }),
    [graph.nodes, dark, selectedId],
  );

  const rels = useMemo<NvlRelationship[]>(() => {
    const present = new Set(graph.nodes.map((n) => n.id));
    return graph.relationships
      .filter((r) => present.has(r.start_node) && present.has(r.end_node))
      .map((r) => ({
        id: relId(r.id),
        from: nodeId(r.start_node),
        to: nodeId(r.end_node),
        captions: showTypes ? [{ value: r.type }] : [],
        color: dark ? '#6b6a65' : '#a8a69e',
      }));
  }, [graph.nodes, graph.relationships, showTypes, dark]);

  useImperativeHandle(
    ref,
    () => ({
      fit: () => nvl.current?.fit(nodes.map((n) => n.id)),
      zoomBy: (factor) => {
        const instance = nvl.current;
        if (instance) instance.setZoom(instance.getScale() * factor);
      },
      savePng: (filename) => nvl.current?.saveToFile({ filename, backgroundColor: dark ? '#0d0d0d' : '#f9f9f7' }),
    }),
    [nodes, dark],
  );

  // Fit a new graph once its layout has settled. The signature changes when
  // the set of nodes does (a new view, an expansion), not on a selection.
  const signature = `${graph.nodes.length}:${graph.nodes[0]?.id ?? ''}:${graph.nodes[graph.nodes.length - 1]?.id ?? ''}`;
  const pendingFit = useRef(false);
  const latestIds = useRef<string[]>([]);
  latestIds.current = nodes.map((n) => n.id);
  const fitNow = () => {
    pendingFit.current = false;
    nvl.current?.fit(latestIds.current);
  };
  useEffect(() => {
    if (graph.nodes.length === 0) return;
    pendingFit.current = true;
    // NVL reports when the layout is done; the timers cover a layout that
    // never reports and give an early, rough fit while it is still moving.
    const early = setTimeout(() => nvl.current?.fit(latestIds.current), 500);
    const late = setTimeout(() => pendingFit.current && fitNow(), 2500);
    return () => {
      clearTimeout(early);
      clearTimeout(late);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [signature]);
  const nvlCallbacks = useMemo(() => ({ onLayoutDone: () => pendingFit.current && fitNow() }), []);

  const callbacks = useMemo<MouseEventCallbacks>(
    () => ({
      onNodeClick: (node) => onSelectNode?.(byId.get(node.id) ?? null),
      onNodeDoubleClick: (node) => {
        const wire = byId.get(node.id);
        if (wire) onExpandNode?.(wire);
      },
      onRelationshipClick: (relationship) => {
        const wire = relById.get(relationship.id);
        if (wire) onSelectRelationship?.(wire);
      },
      onCanvasClick: () => onSelectNode?.(null),
      onDrag: true,
      onPan: true,
      onZoom: true,
    }),
    [byId, relById, onSelectNode, onSelectRelationship, onExpandNode],
  );

  const options = useMemo(
    () => ({
      initialZoom: 1,
      minZoom: 0.05,
      maxZoom: 6,
      // No usage data leaves the page.
      disableTelemetry: true,
      renderer: 'canvas' as const,
      styling: {
        defaultRelationshipColor: dark ? '#6b6a65' : '#a8a69e',
        selectedBorderColor: dark ? '#f0efec' : '#0b0b0b',
        dropShadowColor: dark ? 'rgba(0,0,0,0.6)' : 'rgba(11,11,11,0.25)',
      },
    }),
    [dark],
  );

  if (failed) return <div className="banner error">The graph view could not start: {failed}</div>;
  return (
    <div className="graph-canvas" data-testid="graph-canvas" data-nodes={nodes.length} data-relationships={rels.length}>
      <InteractiveNvlWrapper
        ref={nvl}
        nodes={nodes}
        rels={rels}
        nvlOptions={options}
        nvlCallbacks={nvlCallbacks}
        mouseEventCallbacks={callbacks}
        interactionOptions={{ selectOnClick: false }}
        onInitializationError={(err) => setFailed(err instanceof Error ? err.message : String(err))}
        style={{ width: '100%', height: '100%' }}
      />
    </div>
  );
});
