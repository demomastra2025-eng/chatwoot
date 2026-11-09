<script setup>
import { computed, ref, shallowRef, watch, onBeforeUnmount } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  forceSimulation,
  forceLink,
  forceManyBody,
  forceCollide,
  forceCenter,
  forceRadial,
} from 'd3-force';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  responses: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['navigate']);
const { t } = useI18n();

const VIEWPORT_WIDTH = 1080;
const VIEWPORT_HEIGHT = 640;
const CENTER_X = VIEWPORT_WIDTH / 2;
const CENTER_Y = VIEWPORT_HEIGHT / 2;

const CLUSTER_RULES = [
  {
    key: 'pricing',
    i18nKey: 'PRICING',
    icon: 'i-lucide-banknote',
    keywords: [
      'цен',
      'стоим',
      'прайс',
      'оплат',
      'скидк',
      'акци',
      'тенге',
      'тг',
      'kzt',
      'price',
      'cost',
      'тариф',
      'каспи',
      'kaspi',
      'рассроч',
    ],
    palette: {
      stroke: '#10b981',
      fill: 'rgba(16, 185, 129, 0.16)',
      glow: 'rgba(16, 185, 129, 0.35)',
      chip: 'bg-n-teal-3/70 text-n-teal-11 border-n-teal-6',
      dot: '#10b981',
    },
  },
  {
    key: 'doctors',
    i18nKey: 'DOCTORS',
    icon: 'i-lucide-stethoscope',
    keywords: [
      'врач',
      'доктор',
      'специал',
      'хирург',
      'терапевт',
      'педиатр',
      'гинеколог',
      'невролог',
      'ортопед',
      'стоматолог',
      'кардиолог',
      'лор',
      'уролог',
      'дерматолог',
      'офтальмолог',
      'эндокринолог',
      'doctor',
      'стаж',
    ],
    palette: {
      stroke: '#3b82f6',
      fill: 'rgba(59, 130, 246, 0.16)',
      glow: 'rgba(59, 130, 246, 0.35)',
      chip: 'bg-n-blue-3/70 text-n-blue-11 border-n-blue-6',
      dot: '#3b82f6',
    },
  },
  {
    key: 'booking',
    i18nKey: 'BOOKING',
    icon: 'i-lucide-calendar-check-2',
    keywords: [
      'запис',
      'прием',
      'приём',
      'расписан',
      'время',
      'график',
      'свободн',
      'окошк',
      'отмен',
      'перенес',
      'брон',
      'чекап',
      'check',
      'book',
      'schedule',
      'выходн',
      'часы',
    ],
    palette: {
      stroke: '#8b5cf6',
      fill: 'rgba(139, 92, 246, 0.16)',
      glow: 'rgba(139, 92, 246, 0.35)',
      chip: 'bg-n-violet-3/70 text-n-violet-11 border-n-violet-6',
      dot: '#8b5cf6',
    },
  },
  {
    key: 'preparation',
    i18nKey: 'PREPARATION',
    icon: 'i-lucide-flask-conical',
    keywords: [
      'подготов',
      'анализ',
      'узи',
      'мрт',
      'кт',
      'рентген',
      'экг',
      'кров',
      'натощак',
      'процедур',
      'обслед',
      'диагност',
      'результат',
      'справк',
      'лечен',
    ],
    palette: {
      stroke: '#f59e0b',
      fill: 'rgba(245, 158, 11, 0.16)',
      glow: 'rgba(245, 158, 11, 0.35)',
      chip: 'bg-n-amber-3/70 text-n-amber-11 border-n-amber-6',
      dot: '#f59e0b',
    },
  },
  {
    key: 'location',
    i18nKey: 'LOCATION',
    icon: 'i-lucide-map-pin',
    keywords: [
      'адрес',
      'где',
      'наход',
      'филиал',
      'проезд',
      'парков',
      'этаж',
      'кабинет',
      'контакт',
      'телефон',
      '2гис',
      '2gis',
      'карт',
      'город',
    ],
    palette: {
      stroke: '#ec4899',
      fill: 'rgba(236, 72, 153, 0.16)',
      glow: 'rgba(236, 72, 153, 0.35)',
      chip: 'bg-n-ruby-3/70 text-n-ruby-11 border-n-ruby-6',
      dot: '#ec4899',
    },
  },
];

const DEFAULT_CLUSTER = {
  key: 'general',
  i18nKey: 'GENERAL',
  icon: 'i-lucide-sparkles',
  palette: {
    stroke: '#06b6d4',
    fill: 'rgba(6, 182, 212, 0.16)',
    glow: 'rgba(6, 182, 212, 0.35)',
    chip: 'bg-n-slate-3 text-n-slate-12 border-n-slate-6',
    dot: '#06b6d4',
  },
};

const STOP_WORDS = new Set([
  'как',
  'что',
  'где',
  'для',
  'или',
  'при',
  'это',
  'все',
  'всё',
  'можн',
  'нужн',
  'есть',
  'если',
  'ваш',
  'наш',
  'клиник',
  'котор',
  'после',
  'перед',
  'через',
  'сколько',
  'какие',
  'какой',
  'какая',
  'работа',
  'дела',
]);

const classifyResponse = item => {
  const haystack =
    `${item?.question || ''} ${item?.answer || ''} ${item?.documentable?.name || ''}`.toLowerCase();
  const matched = CLUSTER_RULES.find(rule =>
    rule.keywords.some(keyword => haystack.includes(keyword))
  );
  return matched || DEFAULT_CLUSTER;
};

const extractTokens = text => {
  const cleaned = String(text || '')
    .toLowerCase()
    .replace(/[^a-zа-яёәіңғүұқөһ0-9\s]/gi, ' ');
  const words = cleaned
    .split(/\s+/)
    .filter(w => w.length >= 4 && !STOP_WORDS.has(w))
    .map(w => (w.length > 6 ? w.slice(0, 6) : w));
  return new Set(words);
};

const computeJaccard = (setA, setB) => {
  if (!setA.size || !setB.size) return 0;
  let intersection = 0;
  setA.forEach(token => {
    if (setB.has(token)) intersection += 1;
  });
  if (intersection === 0) return 0;
  return intersection / (setA.size + setB.size - intersection);
};

const truncateText = (value, maxLength = 34) => {
  const clean = String(value || '').trim();
  if (clean.length <= maxLength) return clean;
  return `${clean.slice(0, maxLength - 1)}…`;
};

const activeClusterKey = ref('all');
const selectedNodeId = ref(null);
const hoveredNodeId = ref(null);
const isFullscreen = ref(false);
const copiedAnswer = ref(false);

// Camera pan & zoom state
const zoom = ref(1);
const panX = ref(0);
const panY = ref(0);
const isPanning = ref(false);
const panStart = ref({ x: 0, y: 0, panX: 0, panY: 0 });
const draggedNodeId = ref(null);
const svgRef = ref(null);

// Reactive D3 simulation snapshot
const simNodes = ref([]);
const simEdges = ref([]);
const simulationRef = shallowRef(null);

const normalizedItems = computed(() =>
  (props.responses || []).map((item, index) => {
    const cluster = classifyResponse(item);
    const question = String(item.question || '').trim();
    const answer = String(item.answer || '').trim();
    const docName =
      item.documentable?.type === 'Captain::Document'
        ? String(item.documentable.name || '').trim()
        : '';
    return {
      id: `faq-${item.id ?? index}`,
      rawId: item.id ?? index,
      raw: item,
      question,
      shortQuestion: truncateText(question, 32),
      answer,
      clusterKey: cluster.key,
      clusterLabel: t(`CAPTAIN.KNOWLEDGE_BASE.GRAPH.TOPICS.${cluster.i18nKey}`),
      clusterIcon: cluster.icon,
      palette: cluster.palette,
      docId:
        item.documentable?.type === 'Captain::Document' && item.documentable?.id
          ? `doc-${item.documentable.id}`
          : null,
      docName: docName ? truncateText(docName, 26) : null,
      tokens: extractTokens(`${question} ${answer}`),
    };
  })
);

const clusters = computed(() => {
  const map = new Map();
  normalizedItems.value.forEach(node => {
    const existing = map.get(node.clusterKey);
    if (existing) {
      existing.count += 1;
    } else {
      map.set(node.clusterKey, {
        key: node.clusterKey,
        label: node.clusterLabel,
        icon: node.clusterIcon,
        palette: node.palette,
        count: 1,
      });
    }
  });
  return Array.from(map.values()).sort((a, b) => b.count - a.count);
});

const visibleItems = computed(() => {
  if (activeClusterKey.value === 'all') return normalizedItems.value;
  return normalizedItems.value.filter(
    node => node.clusterKey === activeClusterKey.value
  );
});

const documentSourcesCount = computed(() => {
  const docs = new Set();
  visibleItems.value.forEach(item => {
    if (item.docId) docs.add(item.docId);
  });
  return docs.size;
});

const buildAndRunD3ForceGraph = () => {
  if (simulationRef.value) {
    simulationRef.value.stop();
    simulationRef.value = null;
  }

  const items = visibleItems.value;
  if (!items.length) {
    simNodes.value = [];
    simEdges.value = [];
    return;
  }

  const nodes = [];
  const links = [];

  // 1. Core AI Knowledge Hub
  const showCore =
    activeClusterKey.value === 'all' && clusters.value.length > 1;
  if (showCore) {
    nodes.push({
      id: 'core-hub',
      kind: 'core',
      label: t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.CENTER_HUB'),
      radius: 32,
      x: CENTER_X,
      y: CENTER_Y,
      fx: CENTER_X,
      fy: CENTER_Y,
      palette: {
        stroke: '#3b82f6',
        fill: 'rgba(59, 130, 246, 0.22)',
        glow: 'rgba(59, 130, 246, 0.45)',
        dot: '#3b82f6',
      },
      degree: clusters.value.length,
    });
  }

  // 2. Semantic Cluster Hubs
  const activeClusters =
    activeClusterKey.value === 'all'
      ? clusters.value
      : clusters.value.filter(c => c.key === activeClusterKey.value);

  const clusterAnchors = new Map();
  activeClusters.forEach((cluster, idx) => {
    const angle =
      (idx / Math.max(activeClusters.length, 1)) * Math.PI * 2 - Math.PI / 2;
    const orbit = showCore ? 175 : 0;
    const cx = CENTER_X + Math.cos(angle) * orbit;
    const cy = CENTER_Y + Math.sin(angle) * orbit;
    const clusterNodeId = `cluster-${cluster.key}`;
    clusterAnchors.set(cluster.key, { x: cx, y: cy, angle, id: clusterNodeId });

    nodes.push({
      id: clusterNodeId,
      kind: 'cluster',
      clusterKey: cluster.key,
      label: cluster.label,
      count: cluster.count,
      radius: Math.min(26, 18 + Math.sqrt(cluster.count) * 2.2),
      x: cx,
      y: cy,
      palette: cluster.palette,
      degree: cluster.count,
    });

    if (showCore) {
      links.push({
        id: `link-core-${cluster.key}`,
        source: 'core-hub',
        target: clusterNodeId,
        kind: 'backbone',
        stroke: cluster.palette.stroke,
        distance: 170,
        strength: 0.85,
      });
    }
  });

  // 3. FAQ Knowledge Nodes
  items.forEach((item, idx) => {
    const anchor = clusterAnchors.get(item.clusterKey) || {
      x: CENTER_X,
      y: CENTER_Y,
      angle: 0,
      id: `cluster-${item.clusterKey}`,
    };
    const spreadAngle =
      anchor.angle + ((idx % 9) - 4) * 0.24 + ((idx * 0.61803398875) % 0.5);
    const dist = 85 + (idx % 4) * 32;

    nodes.push({
      id: item.id,
      rawId: item.rawId,
      kind: 'faq',
      label: item.shortQuestion,
      question: item.question,
      answer: item.answer,
      clusterKey: item.clusterKey,
      clusterLabel: item.clusterLabel,
      docName: item.docName,
      raw: item.raw,
      palette: item.palette,
      radius: 9,
      degree: 1,
      x: anchor.x + Math.cos(spreadAngle) * dist,
      y: anchor.y + Math.sin(spreadAngle) * dist,
    });

    links.push({
      id: `link-${anchor.id}-${item.id}`,
      source: anchor.id,
      target: item.id,
      kind: 'topic',
      stroke: item.palette.stroke,
      distance: 92 + (idx % 3) * 18,
      strength: 0.65,
    });
  });

  // 4. Semantic Cross-Links between FAQ nodes (TF/Token Jaccard similarity)
  const degreeCounter = new Map();
  for (let i = 0; i < items.length; i += 1) {
    let bestPeer = null;
    let bestScore = 0;
    for (let j = i + 1; j < items.length; j += 1) {
      const score = computeJaccard(items[i].tokens, items[j].tokens);
      if (score > bestScore && score >= 0.16) {
        bestScore = score;
        bestPeer = items[j];
      }
    }
    if (bestPeer) {
      links.push({
        id: `sem-${items[i].id}-${bestPeer.id}`,
        source: items[i].id,
        target: bestPeer.id,
        kind: 'semantic',
        similarity: bestScore,
        stroke: items[i].palette.stroke,
        distance: 110,
        strength: 0.22,
      });
      degreeCounter.set(items[i].id, (degreeCounter.get(items[i].id) || 1) + 1);
      degreeCounter.set(bestPeer.id, (degreeCounter.get(bestPeer.id) || 1) + 1);
    }
  }

  nodes.forEach(n => {
    if (n.kind === 'faq') {
      const deg = degreeCounter.get(n.id) || 1;
      n.degree = deg;
      n.radius = Math.min(15, 7.5 + deg * 1.6);
    }
  });

  // 5. Configure D3-Force Simulation
  const sim = forceSimulation(nodes)
    .force(
      'link',
      forceLink(links)
        .id(d => d.id)
        .distance(d => d.distance || 100)
        .strength(d => d.strength || 0.5)
    )
    .force(
      'charge',
      forceManyBody().strength(d => {
        if (d.kind === 'core') return -650;
        if (d.kind === 'cluster') return -420;
        return -150;
      })
    )
    .force(
      'collide',
      forceCollide()
        .radius(d => {
          if (d.kind === 'core') return d.radius + 26;
          if (d.kind === 'cluster') return d.radius + 22;
          return d.radius + 16;
        })
        .iterations(3)
    )
    .force('center', forceCenter(CENTER_X, CENTER_Y).strength(0.06))
    .force(
      'radial',
      forceRadial(
        d => {
          if (d.kind === 'core') return 0;
          if (d.kind === 'cluster') return showCore ? 175 : 0;
          return showCore ? 265 : 145;
        },
        CENTER_X,
        CENTER_Y
      ).strength(d => (d.kind === 'cluster' ? 0.35 : 0.12))
    )
    .alphaDecay(0.035);

  // Pre-warm 130 ticks synchronously so initial mount & unit tests have settled physics
  sim.tick(130);

  const syncSnapshot = () => {
    simNodes.value = nodes.map(n => ({
      ...n,
      x: Math.max(48, Math.min(VIEWPORT_WIDTH - 48, n.x || CENTER_X)),
      y: Math.max(42, Math.min(VIEWPORT_HEIGHT - 42, n.y || CENTER_Y)),
    }));
    simEdges.value = links.map(l => ({
      id: l.id,
      kind: l.kind,
      stroke: l.stroke,
      sourceId: typeof l.source === 'object' ? l.source.id : l.source,
      targetId: typeof l.target === 'object' ? l.target.id : l.target,
      x1: typeof l.source === 'object' ? l.source.x : CENTER_X,
      y1: typeof l.source === 'object' ? l.source.y : CENTER_Y,
      x2: typeof l.target === 'object' ? l.target.x : CENTER_X,
      y2: typeof l.target === 'object' ? l.target.y : CENTER_Y,
    }));
  };

  syncSnapshot();

  sim.on('tick', () => {
    syncSnapshot();
  });

  // Stop background timer after pre-warming; user drag or reheat button restarts it
  sim.stop();
  simulationRef.value = sim;
};

watch(
  [visibleItems, activeClusterKey],
  () => {
    buildAndRunD3ForceGraph();
    const faqNodes = simNodes.value.filter(n => n.kind === 'faq');
    if (
      !faqNodes.some(n => n.rawId === selectedNodeId.value) &&
      faqNodes.length > 0
    ) {
      selectedNodeId.value = faqNodes[0].rawId;
    }
  },
  { immediate: true }
);

onBeforeUnmount(() => {
  if (simulationRef.value) {
    simulationRef.value.stop();
  }
});

const faqNodes = computed(() => simNodes.value.filter(n => n.kind === 'faq'));
const clusterNodes = computed(() =>
  simNodes.value.filter(n => n.kind === 'cluster')
);
const coreNode = computed(
  () => simNodes.value.find(n => n.kind === 'core') || null
);

const selectedNode = computed(() => {
  if (!faqNodes.value.length) return null;
  return (
    faqNodes.value.find(node => node.rawId === selectedNodeId.value) ||
    faqNodes.value[0]
  );
});

const activeFocusId = computed(() => {
  if (hoveredNodeId.value) return hoveredNodeId.value;
  return selectedNode.value?.id || null;
});

// 1-Hop neighborhood set for spotlight highlighting
const connectedNodeIds = computed(() => {
  const focusId = activeFocusId.value;
  if (!focusId) return new Set();
  const set = new Set([focusId]);
  simEdges.value.forEach(edge => {
    if (edge.sourceId === focusId) set.add(edge.targetId);
    if (edge.targetId === focusId) set.add(edge.sourceId);
  });
  return set;
});

const isEdgeHighlighted = edge => {
  const focusId = activeFocusId.value;
  if (!focusId) return false;
  return edge.sourceId === focusId || edge.targetId === focusId;
};

const isNodeDimmed = nodeId => {
  if (!hoveredNodeId.value) return false;
  return !connectedNodeIds.value.has(nodeId);
};

const semanticPeers = computed(() => {
  if (!selectedNode.value) return [];
  const targetId = selectedNode.value.id;
  const peerIds = new Set();
  simEdges.value.forEach(edge => {
    if (edge.kind === 'semantic') {
      if (edge.sourceId === targetId) peerIds.add(edge.targetId);
      if (edge.targetId === targetId) peerIds.add(edge.sourceId);
    }
  });
  return faqNodes.value.filter(n => peerIds.has(n.id)).slice(0, 5);
});

const relatedClusterNodes = computed(() => {
  if (!selectedNode.value) return [];
  return faqNodes.value
    .filter(
      node =>
        node.clusterKey === selectedNode.value.clusterKey &&
        node.rawId !== selectedNode.value.rawId
    )
    .slice(0, 6);
});

const curvePath = edge => {
  const dx = edge.x2 - edge.x1;
  const dy = edge.y2 - edge.y1;
  const curvature = edge.kind === 'semantic' ? 0.22 : 0.12;
  const cx = (edge.x1 + edge.x2) / 2 - dy * curvature;
  const cy = (edge.y1 + edge.y2) / 2 + dx * curvature;
  return `M ${edge.x1} ${edge.y1} Q ${cx} ${cy} ${edge.x2} ${edge.y2}`;
};

const selectCluster = key => {
  activeClusterKey.value = key;
  panX.value = 0;
  panY.value = 0;
};

const selectNode = rawId => {
  selectedNodeId.value = rawId;
};

const reheatPhysics = () => {
  if (!simulationRef.value) return;
  simulationRef.value.alpha(0.65).restart();
  setTimeout(() => {
    if (simulationRef.value) simulationRef.value.stop();
  }, 1800);
};

const adjustZoom = delta => {
  const next = Number((zoom.value + delta).toFixed(2));
  zoom.value = Math.min(2.4, Math.max(0.5, next));
};

const resetCamera = () => {
  zoom.value = 1;
  panX.value = 0;
  panY.value = 0;
};

const onWheelZoom = event => {
  event.preventDefault();
  const delta = event.deltaY < 0 ? 0.12 : -0.12;
  adjustZoom(delta);
};

const clientToSvgCoords = event => {
  const svg = svgRef.value;
  if (!svg) return { x: CENTER_X, y: CENTER_Y };
  const rect = svg.getBoundingClientRect();
  const scaleX = VIEWPORT_WIDTH / Math.max(rect.width, 1);
  const scaleY = VIEWPORT_HEIGHT / Math.max(rect.height, 1);
  const rawX = (event.clientX - rect.left) * scaleX;
  const rawY = (event.clientY - rect.top) * scaleY;
  return {
    x: (rawX - CENTER_X - panX.value) / zoom.value + CENTER_X,
    y: (rawY - CENTER_Y - panY.value) / zoom.value + CENTER_Y,
  };
};

const onNodePointerDown = (event, node) => {
  event.stopPropagation();
  if (node.kind === 'faq') {
    selectedNodeId.value = node.rawId;
  }
  draggedNodeId.value = node.id;
  if (simulationRef.value) {
    const simNode = simulationRef.value.nodes().find(n => n.id === node.id);
    if (simNode) {
      simNode.fx = simNode.x;
      simNode.fy = simNode.y;
      simulationRef.value.alphaTarget(0.3).restart();
    }
  }
};

const onCanvasPointerDown = event => {
  if (draggedNodeId.value) return;
  isPanning.value = true;
  panStart.value = {
    x: event.clientX,
    y: event.clientY,
    panX: panX.value,
    panY: panY.value,
  };
};

const onCanvasPointerMove = event => {
  if (draggedNodeId.value && simulationRef.value) {
    const coords = clientToSvgCoords(event);
    const simNode = simulationRef.value
      .nodes()
      .find(n => n.id === draggedNodeId.value);
    if (simNode) {
      simNode.fx = Math.max(48, Math.min(VIEWPORT_WIDTH - 48, coords.x));
      simNode.fy = Math.max(42, Math.min(VIEWPORT_HEIGHT - 42, coords.y));
    }
    return;
  }
  if (isPanning.value) {
    panX.value = panStart.value.panX + (event.clientX - panStart.value.x);
    panY.value = panStart.value.panY + (event.clientY - panStart.value.y);
  }
};

const onCanvasPointerUp = () => {
  if (draggedNodeId.value && simulationRef.value) {
    const simNode = simulationRef.value
      .nodes()
      .find(n => n.id === draggedNodeId.value);
    if (simNode && simNode.kind !== 'core') {
      simNode.fx = null;
      simNode.fy = null;
    }
    simulationRef.value.alphaTarget(0);
    setTimeout(() => {
      if (simulationRef.value && !draggedNodeId.value) {
        simulationRef.value.stop();
      }
    }, 900);
  }
  draggedNodeId.value = null;
  isPanning.value = false;
};

const copyAnswerToClipboard = async () => {
  if (!selectedNode.value?.answer) return;
  try {
    await navigator.clipboard?.writeText(selectedNode.value.answer);
    copiedAnswer.value = true;
    setTimeout(() => {
      copiedAnswer.value = false;
    }, 1800);
  } catch {
    copiedAnswer.value = false;
  }
};

const handleSourceClick = documentable => {
  if (!documentable) return;
  if (documentable.type === 'Conversation') {
    emit('navigate', {
      id: documentable.display_id,
      type: 'Conversation',
    });
  }
};
</script>

<template>
  <div
    class="flex flex-col gap-4"
    :class="
      isFullscreen
        ? 'fixed inset-4 z-50 rounded-2xl border border-n-weak bg-n-surface-1 p-5 shadow-2xl overflow-y-auto'
        : ''
    "
    data-testid="knowledge-graph-cloud"
  >
    <!-- Top Topic Filter Bar & Read-Only / Engine Status -->
    <div
      class="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-n-weak bg-n-solid-2 px-4 py-3"
    >
      <div class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          class="inline-flex items-center gap-2 rounded-xl border px-3 py-1.5 text-xs font-medium transition-all"
          :class="
            activeClusterKey === 'all'
              ? 'border-n-brand bg-n-brand/10 text-n-blue-11 shadow-sm'
              : 'border-n-weak bg-n-surface-1 text-n-slate-11 hover:text-n-slate-12'
          "
          @click="selectCluster('all')"
        >
          <Icon icon="i-lucide-orbit" class="size-3.5" />
          <span>{{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ALL_TOPICS') }}</span>
          <span
            class="rounded-full bg-n-alpha-2 px-1.5 py-0.5 text-[11px] font-semibold"
          >
            {{ normalizedItems.length }}
          </span>
        </button>

        <button
          v-for="cluster in clusters"
          :key="cluster.key"
          type="button"
          class="inline-flex items-center gap-2 rounded-xl border px-3 py-1.5 text-xs font-medium transition-all"
          :class="
            activeClusterKey === cluster.key
              ? cluster.palette.chip
              : 'border-n-weak bg-n-surface-1 text-n-slate-11 hover:text-n-slate-12'
          "
          data-testid="knowledge-cluster-chip"
          @click="selectCluster(cluster.key)"
        >
          <span
            class="size-2 rounded-full"
            :style="{ backgroundColor: cluster.palette.dot }"
          />
          <span>{{ cluster.label }}</span>
          <span class="opacity-75">({{ cluster.count }})</span>
        </button>
      </div>

      <div class="flex items-center gap-2">
        <span
          class="inline-flex items-center gap-1.5 rounded-lg border border-n-blue-6/50 bg-n-blue-3/40 px-2.5 py-1 text-[11px] font-medium text-n-blue-11"
        >
          <Icon icon="i-lucide-cpu" class="size-3.5" />
          {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ENGINE_BADGE') }}
        </span>
        <span
          class="inline-flex items-center gap-1.5 rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-1 text-xs text-n-slate-11"
        >
          <Icon icon="i-lucide-lock" class="size-3.5 text-n-slate-10" />
          {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.READ_ONLY_BADGE') }}
        </span>
      </div>
    </div>

    <!-- Main Split View: D3-Force Interactive Canvas + Knowledge Inspector -->
    <div class="grid grid-cols-1 gap-4 lg:grid-cols-12">
      <!-- D3-Force Interactive Constellation Canvas -->
      <div
        class="relative flex flex-col overflow-hidden rounded-2xl border border-n-weak bg-n-solid-2 lg:col-span-7"
      >
        <!-- Floating HUD Controls -->
        <div
          class="flex flex-wrap items-center justify-between gap-2 border-b border-n-weak px-4 py-2.5 text-xs text-n-slate-11"
        >
          <div class="flex flex-wrap items-center gap-3">
            <span
              class="inline-flex items-center gap-1.5 font-medium text-n-slate-12"
            >
              <Icon icon="i-lucide-waypoints" class="size-3.5 text-n-brand" />
              {{
                t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.NODES_COUNT', {
                  count: faqNodes.length,
                })
              }}
            </span>
            <span class="text-n-slate-8">•</span>
            <span>
              {{
                t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.EDGES_COUNT', {
                  count: simEdges.length,
                })
              }}
            </span>
            <template v-if="documentSourcesCount > 0">
              <span class="text-n-slate-8">•</span>
              <span>
                {{
                  t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.SOURCES_COUNT', {
                    count: documentSourcesCount,
                  })
                }}
              </span>
            </template>
          </div>

          <div class="flex items-center gap-1">
            <Button
              icon="i-lucide-flame"
              size="xs"
              variant="ghost"
              color="slate"
              :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.REHEAT_PHYSICS')"
              data-testid="knowledge-graph-reheat"
              @click="reheatPhysics"
            />
            <Button
              icon="i-lucide-zoom-out"
              size="xs"
              variant="ghost"
              color="slate"
              :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ZOOM_OUT')"
              @click="adjustZoom(-0.18)"
            />
            <Button
              icon="i-lucide-maximize-2"
              size="xs"
              variant="ghost"
              color="slate"
              :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.FIT_VIEW')"
              @click="resetCamera"
            />
            <Button
              icon="i-lucide-zoom-in"
              size="xs"
              variant="ghost"
              color="slate"
              :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ZOOM_IN')"
              @click="adjustZoom(0.18)"
            />
            <Button
              :icon="isFullscreen ? 'i-lucide-minimize' : 'i-lucide-expand'"
              size="xs"
              variant="ghost"
              color="slate"
              :title="
                isFullscreen
                  ? t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.EXIT_FULLSCREEN')
                  : t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.FULLSCREEN')
              "
              @click="isFullscreen = !isFullscreen"
            />
          </div>
        </div>

        <!-- Interactive SVG Force Stage -->
        <div
          class="relative flex items-center justify-center overflow-hidden bg-gradient-to-b from-n-surface-1 via-n-solid-2 to-n-surface-1 select-none"
          :class="[
            isFullscreen ? 'h-[calc(100vh-14rem)]' : 'h-[520px]',
            draggedNodeId
              ? 'cursor-grabbing'
              : isPanning
                ? 'cursor-grabbing'
                : 'cursor-grab',
          ]"
          @wheel="onWheelZoom"
          @pointerdown="onCanvasPointerDown"
          @pointermove="onCanvasPointerMove"
          @pointerup="onCanvasPointerUp"
          @pointerleave="onCanvasPointerUp"
        >
          <svg
            ref="svgRef"
            :viewBox="`0 0 ${VIEWPORT_WIDTH} ${VIEWPORT_HEIGHT}`"
            class="h-full w-full"
          >
            <defs>
              <!-- Subtle Obsidian-style dot grid -->
              <pattern
                id="knowledge-force-grid"
                width="28"
                height="28"
                patternUnits="userSpaceOnUse"
              >
                <circle
                  cx="2"
                  cy="2"
                  r="1"
                  fill="currentColor"
                  class="text-n-slate-7/35"
                />
              </pattern>

              <!-- Ambient Radial Glow -->
              <radialGradient id="core-nebula-glow" cx="50%" cy="50%" r="50%">
                <stop offset="0%" stop-color="#3b82f6" stop-opacity="0.18" />
                <stop offset="60%" stop-color="#8b5cf6" stop-opacity="0.05" />
                <stop offset="100%" stop-color="#3b82f6" stop-opacity="0" />
              </radialGradient>

              <filter
                id="node-soft-glow"
                x="-40%"
                y="-40%"
                width="180%"
                height="180%"
              >
                <feGaussianBlur stdDeviation="4" result="blur" />
                <feComposite in="SourceGraphic" in2="blur" operator="over" />
              </filter>
            </defs>

            <rect
              width="100%"
              height="100%"
              fill="url(#knowledge-force-grid)"
            />

            <g
              :transform="`translate(${CENTER_X + panX}, ${CENTER_Y + panY}) scale(${zoom}) translate(${-CENTER_X}, ${-CENTER_Y})`"
            >
              <!-- Ambient Nebula Aura -->
              <circle
                :cx="CENTER_X"
                :cy="CENTER_Y"
                r="290"
                fill="url(#core-nebula-glow)"
                class="pointer-events-none"
              />

              <!-- Orbit Guide Rings -->
              <template v-if="coreNode">
                <circle
                  :cx="CENTER_X"
                  :cy="CENTER_Y"
                  r="175"
                  fill="none"
                  stroke="currentColor"
                  stroke-dasharray="3 7"
                  class="text-n-slate-6/40 pointer-events-none"
                />
                <circle
                  :cx="CENTER_X"
                  :cy="CENTER_Y"
                  r="270"
                  fill="none"
                  stroke="currentColor"
                  stroke-dasharray="2 9"
                  class="text-n-slate-6/25 pointer-events-none"
                />
              </template>

              <!-- Graph Edges (Backbone + Topic + Semantic Cross-Links) -->
              <g>
                <template v-for="edge in simEdges" :key="edge.id">
                  <path
                    :d="curvePath(edge)"
                    fill="none"
                    :stroke="edge.stroke"
                    :stroke-width="
                      isEdgeHighlighted(edge)
                        ? 2.6
                        : edge.kind === 'backbone'
                          ? 1.9
                          : edge.kind === 'semantic'
                            ? 1.15
                            : 1.4
                    "
                    :stroke-dasharray="
                      edge.kind === 'semantic' ? '4 5' : undefined
                    "
                    :stroke-opacity="
                      isEdgeHighlighted(edge)
                        ? 0.92
                        : hoveredNodeId
                          ? 0.12
                          : edge.kind === 'backbone'
                            ? 0.48
                            : edge.kind === 'semantic'
                              ? 0.28
                              : 0.34
                    "
                    stroke-linecap="round"
                    class="transition-opacity duration-200"
                  />
                  <!-- Animated energy pulse on highlighted edges -->
                  <path
                    v-if="isEdgeHighlighted(edge)"
                    :d="curvePath(edge)"
                    fill="none"
                    :stroke="edge.stroke"
                    stroke-width="3"
                    stroke-dasharray="6 14"
                    stroke-linecap="round"
                    class="knowledge-edge-pulse pointer-events-none"
                  />
                </template>
              </g>

              <!-- Core Knowledge Hub Node -->
              <g
                v-if="coreNode"
                class="cursor-pointer"
                @pointerdown="onNodePointerDown($event, coreNode)"
                @pointerenter="hoveredNodeId = coreNode.id"
                @pointerleave="hoveredNodeId = null"
                @click.stop="selectCluster('all')"
              >
                <circle
                  :cx="coreNode.x"
                  :cy="coreNode.y"
                  :r="coreNode.radius + 10"
                  fill="rgba(59, 130, 246, 0.08)"
                  stroke="#3b82f6"
                  stroke-opacity="0.35"
                  stroke-width="1.2"
                  stroke-dasharray="4 4"
                />
                <circle
                  :cx="coreNode.x"
                  :cy="coreNode.y"
                  :r="coreNode.radius"
                  fill="rgba(59, 130, 246, 0.2)"
                  stroke="#3b82f6"
                  stroke-width="2.4"
                  filter="url(#node-soft-glow)"
                />
                <circle
                  :cx="coreNode.x"
                  :cy="coreNode.y"
                  r="7"
                  fill="#3b82f6"
                />
                <g :transform="`translate(${coreNode.x}, ${coreNode.y + 48})`">
                  <rect
                    x="-68"
                    y="-11"
                    width="136"
                    height="22"
                    rx="11"
                    class="fill-n-surface-1/95 stroke-n-blue-6"
                    stroke-width="1"
                  />
                  <text
                    x="0"
                    y="4"
                    text-anchor="middle"
                    class="fill-n-slate-12 text-[11px] font-semibold"
                  >
                    {{ coreNode.label }}
                  </text>
                </g>
              </g>

              <!-- Semantic Cluster Hub Nodes -->
              <g
                v-for="cluster in clusterNodes"
                :key="cluster.id"
                class="cursor-pointer transition-opacity duration-200"
                :class="{ 'opacity-25': isNodeDimmed(cluster.id) }"
                @pointerdown="onNodePointerDown($event, cluster)"
                @pointerenter="hoveredNodeId = cluster.id"
                @pointerleave="hoveredNodeId = null"
                @click.stop="selectCluster(cluster.clusterKey)"
              >
                <circle
                  :cx="cluster.x"
                  :cy="cluster.y"
                  :r="cluster.radius + 6"
                  :fill="cluster.palette.fill"
                  opacity="0.45"
                />
                <circle
                  :cx="cluster.x"
                  :cy="cluster.y"
                  :r="cluster.radius"
                  :fill="cluster.palette.fill"
                  :stroke="cluster.palette.stroke"
                  stroke-width="2.2"
                />
                <text
                  :x="cluster.x"
                  :y="cluster.y + 4"
                  text-anchor="middle"
                  class="fill-n-slate-12 text-[11px] font-bold"
                >
                  {{ cluster.count }}
                </text>
                <g
                  :transform="`translate(${cluster.x}, ${cluster.y - cluster.radius - 14})`"
                >
                  <rect
                    :x="-Math.max(48, cluster.label.length * 3.6)"
                    y="-10"
                    :width="Math.max(96, cluster.label.length * 7.2)"
                    height="20"
                    rx="10"
                    class="fill-n-surface-1/90 stroke-n-weak"
                    stroke-width="1"
                  />
                  <text
                    x="0"
                    y="3.5"
                    text-anchor="middle"
                    class="fill-n-slate-12 text-[10.5px] font-semibold"
                  >
                    {{ cluster.label }}
                  </text>
                </g>
              </g>

              <!-- FAQ Knowledge Leaf Nodes -->
              <g
                v-for="node in faqNodes"
                :key="node.id"
                class="cursor-pointer transition-opacity duration-200"
                :class="{ 'opacity-20': isNodeDimmed(node.id) }"
                data-testid="knowledge-graph-node"
                @pointerdown="onNodePointerDown($event, node)"
                @pointerenter="hoveredNodeId = node.id"
                @pointerleave="hoveredNodeId = null"
                @click.stop="selectNode(node.rawId)"
              >
                <!-- Outer Halo for Selected / Hovered Node -->
                <circle
                  v-if="
                    (selectedNode && selectedNode.rawId === node.rawId) ||
                    hoveredNodeId === node.id
                  "
                  :cx="node.x"
                  :cy="node.y"
                  :r="node.radius + 7"
                  :fill="node.palette.fill"
                  :stroke="node.palette.stroke"
                  stroke-width="1.5"
                  stroke-opacity="0.7"
                />

                <!-- Node Sphere -->
                <circle
                  :cx="node.x"
                  :cy="node.y"
                  :r="
                    selectedNode && selectedNode.rawId === node.rawId
                      ? node.radius + 2.5
                      : node.radius
                  "
                  :fill="
                    selectedNode && selectedNode.rawId === node.rawId
                      ? node.palette.dot
                      : node.palette.fill
                  "
                  :stroke="node.palette.stroke"
                  :stroke-width="
                    selectedNode && selectedNode.rawId === node.rawId
                      ? 2.5
                      : 1.7
                  "
                />

                <!-- Inner Core Dot -->
                <circle
                  :cx="node.x"
                  :cy="node.y"
                  r="2.6"
                  :fill="
                    selectedNode && selectedNode.rawId === node.rawId
                      ? '#ffffff'
                      : node.palette.dot
                  "
                />

                <!-- Pill Label Badge -->
                <g
                  :transform="`translate(${node.x}, ${node.y + node.radius + 15})`"
                >
                  <rect
                    v-if="
                      (selectedNode && selectedNode.rawId === node.rawId) ||
                      hoveredNodeId === node.id
                    "
                    :x="-Math.max(54, node.label.length * 3.4)"
                    y="-10"
                    :width="Math.max(108, node.label.length * 6.8)"
                    height="19"
                    rx="9.5"
                    class="fill-n-surface-1/95 stroke-n-strong"
                    stroke-width="1"
                  />
                  <text
                    x="0"
                    y="3"
                    text-anchor="middle"
                    class="text-[10.5px] transition-all"
                    :class="
                      (selectedNode && selectedNode.rawId === node.rawId) ||
                      hoveredNodeId === node.id
                        ? 'fill-n-slate-12 font-semibold'
                        : 'fill-n-slate-11'
                    "
                  >
                    {{ node.label }}
                  </text>
                </g>
              </g>
            </g>
          </svg>

          <!-- Bottom Floating Hint Pill -->
          <div
            class="pointer-events-none absolute bottom-3 left-3 flex items-center gap-2 rounded-xl border border-n-weak bg-n-surface-1/85 px-3 py-1.5 text-[11px] text-n-slate-11 backdrop-blur-sm"
          >
            <Icon icon="i-lucide-move" class="size-3.5 text-n-brand" />
            <span>{{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.DRAG_HINT') }}</span>
          </div>
        </div>
      </div>

      <!-- Read-Only Knowledge Node Inspector -->
      <div
        class="flex flex-col justify-between rounded-2xl border border-n-weak bg-n-solid-2 p-5 lg:col-span-5"
      >
        <div v-if="selectedNode" class="flex flex-col gap-4">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span
              class="inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-medium"
              :class="selectedNode.palette.chip"
            >
              <span
                class="size-2 rounded-full"
                :style="{ backgroundColor: selectedNode.palette.dot }"
              />
              {{ selectedNode.clusterLabel }}
            </span>

            <div
              v-if="selectedNode.raw.documentable"
              class="inline-flex items-center gap-1.5 rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-1 text-xs text-n-slate-11"
            >
              <Icon
                icon="i-lucide-file-text"
                class="size-3.5 shrink-0 text-n-brand"
              />
              <span
                v-if="
                  selectedNode.raw.documentable.type === 'Captain::Document'
                "
                class="max-w-48 truncate"
                :title="selectedNode.raw.documentable.name"
              >
                {{ selectedNode.raw.documentable.name }}
              </span>
              <button
                v-else-if="
                  selectedNode.raw.documentable.type === 'Conversation'
                "
                type="button"
                class="hover:underline"
                @click="handleSourceClick(selectedNode.raw.documentable)"
              >
                {{
                  t('CAPTAIN.RESPONSES.DOCUMENTABLE.CONVERSATION', {
                    id: selectedNode.raw.documentable.display_id,
                  })
                }}
              </button>
            </div>
          </div>

          <div class="flex flex-col gap-1.5">
            <span
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.QUESTION_LABEL') }}
            </span>
            <h3 class="m-0 text-base font-semibold leading-6 text-n-slate-12">
              {{ selectedNode.question }}
            </h3>
          </div>

          <div
            class="flex flex-col gap-2 rounded-xl border border-n-weak bg-n-surface-1 p-4"
          >
            <div class="flex items-center justify-between gap-2">
              <span
                class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
              >
                {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ANSWER_LABEL') }}
              </span>
              <button
                type="button"
                class="inline-flex items-center gap-1 rounded-lg px-2 py-0.5 text-xs text-n-slate-11 transition-colors hover:bg-n-alpha-2 hover:text-n-slate-12"
                @click="copyAnswerToClipboard"
              >
                <Icon
                  :icon="copiedAnswer ? 'i-lucide-check' : 'i-lucide-copy'"
                  class="size-3.5"
                />
                <span>
                  {{
                    copiedAnswer
                      ? t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.COPIED')
                      : t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.COPY_ANSWER')
                  }}
                </span>
              </button>
            </div>
            <p
              class="m-0 whitespace-pre-line text-sm leading-relaxed text-n-slate-12"
            >
              {{ selectedNode.answer }}
            </p>
          </div>

          <!-- Semantically Connected Knowledge Nodes -->
          <div v-if="semanticPeers.length" class="flex flex-col gap-2 pt-1">
            <span
              class="inline-flex items-center gap-1.5 text-xs font-medium text-n-slate-11"
            >
              <Icon icon="i-lucide-sparkles" class="size-3.5 text-n-brand" />
              {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.SIMILAR_NODES') }}
            </span>
            <div class="flex flex-wrap gap-1.5">
              <button
                v-for="peer in semanticPeers"
                :key="peer.id"
                type="button"
                class="inline-flex items-center gap-1.5 rounded-lg border border-n-blue-6/40 bg-n-blue-3/25 px-2.5 py-1.5 text-left text-xs text-n-slate-12 transition-colors hover:border-n-brand"
                @click="selectNode(peer.rawId)"
              >
                <span
                  class="size-1.5 rounded-full"
                  :style="{ backgroundColor: peer.palette.dot }"
                />
                <span>{{ peer.label }}</span>
              </button>
            </div>
          </div>

          <!-- Other Nodes in the Same Cluster -->
          <div
            v-if="relatedClusterNodes.length"
            class="flex flex-col gap-2 pt-1"
          >
            <span class="text-xs font-medium text-n-slate-11">
              {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.RELATED_QUESTIONS') }}
            </span>
            <div class="flex flex-wrap gap-1.5">
              <button
                v-for="rel in relatedClusterNodes"
                :key="rel.id"
                type="button"
                class="rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-1.5 text-left text-xs text-n-slate-11 transition-colors hover:border-n-brand/40 hover:text-n-slate-12"
                @click="selectNode(rel.rawId)"
              >
                {{ rel.label }}
              </button>
            </div>
          </div>
        </div>

        <div
          v-else
          class="flex h-full items-center justify-center text-center text-sm text-n-slate-11"
        >
          {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.SELECT_NODE_HINT') }}
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
@keyframes knowledgeEdgeFlow {
  from {
    stroke-dashoffset: 40;
  }
  to {
    stroke-dashoffset: 0;
  }
}

.knowledge-edge-pulse {
  animation: knowledgeEdgeFlow 1.2s linear infinite;
}
</style>
