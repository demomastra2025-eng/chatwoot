<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  responses: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['navigate']);

const { t } = useI18n();

const activeClusterKey = ref('all');
const selectedNodeId = ref(null);
const zoom = ref(1);

const CLUSTER_PALETTE = [
  {
    stroke: '#3b82f6',
    fill: 'rgba(59, 130, 246, 0.14)',
    dot: '#2563eb',
    chip: 'border-n-blue-9/30 bg-n-blue-9/10 text-n-blue-11',
  },
  {
    stroke: '#10b981',
    fill: 'rgba(16, 185, 129, 0.14)',
    dot: '#059669',
    chip: 'border-n-teal-9/30 bg-n-teal-9/10 text-n-teal-11',
  },
  {
    stroke: '#8b5cf6',
    fill: 'rgba(139, 92, 246, 0.14)',
    dot: '#7c3aed',
    chip: 'border-n-iris-9/30 bg-n-iris-9/10 text-n-iris-11',
  },
  {
    stroke: '#f59e0b',
    fill: 'rgba(245, 158, 11, 0.14)',
    dot: '#d97706',
    chip: 'border-n-amber-9/30 bg-n-amber-9/10 text-n-amber-11',
  },
  {
    stroke: '#ec4899',
    fill: 'rgba(236, 72, 153, 0.14)',
    dot: '#db2777',
    chip: 'border-n-ruby-9/30 bg-n-ruby-9/10 text-n-ruby-11',
  },
  {
    stroke: '#06b6d4',
    fill: 'rgba(6, 182, 212, 0.14)',
    dot: '#0891b2',
    chip: 'border-n-slate-8 bg-n-alpha-2 text-n-slate-12',
  },
];

const topicRules = computed(() => [
  {
    key: 'pricing',
    label: t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.TOPICS.PRICING'),
    regex: /цен|стоим|прайс|тариф|оплат|тенге|тг|₸|скидк|сколько стоит/i,
  },
  {
    key: 'doctors',
    label: t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.TOPICS.DOCTORS'),
    regex:
      /врач|доктор|специалист|хирург|терапевт|педиатр|кардиолог|невролог|узи|стаж|прием ведет/i,
  },
  {
    key: 'booking',
    label: t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.TOPICS.BOOKING'),
    regex: /запис|график|расписан|время работ|часы|выходн|когда|очеред|отмен/i,
  },
  {
    key: 'preparation',
    label: t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.TOPICS.PREPARATION'),
    regex: /подготов|натощак|анализ|кров|мрт|кт|экг|противопоказан|результат/i,
  },
  {
    key: 'location',
    label: t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.TOPICS.LOCATION'),
    regex: /адрес|кабинет|каб\.|этаж|филиал|проехать|парковк|где находит/i,
  },
]);

const classifyResponse = item => {
  if (
    item.documentable?.type === 'Captain::Document' &&
    item.documentable?.name
  ) {
    const rawName = String(item.documentable.name).replace(
      /\.[a-z0-9]{2,5}$/i,
      ''
    );
    return {
      key: `doc:${item.documentable.id || rawName}`,
      label: rawName.length > 28 ? `${rawName.slice(0, 26)}…` : rawName,
    };
  }
  const text = `${item.question || ''} ${item.answer || ''}`;
  const matched = topicRules.value.find(rule => rule.regex.test(text));
  if (matched) {
    return {
      key: `topic:${matched.key}`,
      label: matched.label,
    };
  }
  if (item.assistant?.name) {
    return {
      key: `assistant:${item.assistant.id || item.assistant.name}`,
      label: item.assistant.name,
    };
  }
  return {
    key: 'topic:general',
    label: t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.TOPICS.GENERAL'),
  };
};

const shortLabel = (text, max = 34) => {
  const clean = String(text || '')
    .trim()
    .replace(/\s+/g, ' ');
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
};

const clusters = computed(() => {
  const map = new Map();
  props.responses.forEach(item => {
    const group = classifyResponse(item);
    if (!map.has(group.key)) {
      const palette = CLUSTER_PALETTE[map.size % CLUSTER_PALETTE.length];
      map.set(group.key, {
        key: group.key,
        label: group.label,
        palette,
        items: [],
      });
    }
    map.get(group.key).items.push(item);
  });
  return Array.from(map.values());
});

const visibleClusters = computed(() => {
  if (activeClusterKey.value === 'all') return clusters.value;
  return clusters.value.filter(
    cluster => cluster.key === activeClusterKey.value
  );
});

const graphLayout = computed(() => {
  const cx = 420;
  const cy = 290;
  const clusterList = visibleClusters.value;
  const clusterCount = clusterList.length || 1;
  const clusterRadius = clusterCount === 1 ? 0 : 145;

  const clusterNodes = [];
  const leafNodes = [];
  const edges = [];

  clusterList.forEach((cluster, cIdx) => {
    const angle =
      clusterCount === 1
        ? -Math.PI / 2
        : (2 * Math.PI * cIdx) / clusterCount - Math.PI / 2;
    const hx = clusterCount === 1 ? cx : cx + Math.cos(angle) * clusterRadius;
    const hy = clusterCount === 1 ? cy : cy + Math.sin(angle) * clusterRadius;

    clusterNodes.push({
      id: `cluster-${cluster.key}`,
      key: cluster.key,
      label: cluster.label,
      count: cluster.items.length,
      x: hx,
      y: hy,
      palette: cluster.palette,
    });

    if (clusterCount > 1) {
      edges.push({
        id: `edge-root-${cluster.key}`,
        x1: cx,
        y1: cy,
        x2: hx,
        y2: hy,
        stroke: cluster.palette.stroke,
        isPrimary: true,
      });
    }

    const totalItems = cluster.items.length;
    const fanSpread =
      clusterCount === 1
        ? Math.PI * 1.85
        : Math.min(Math.PI * 0.85, Math.max(0.55, totalItems * 0.24));
    cluster.items.forEach((item, idx) => {
      const ring = Math.floor(idx / 6);
      const idxInRing = idx % 6;
      const countInRing = Math.min(6, totalItems - ring * 6);
      const offsetRatio =
        countInRing <= 1 ? 0 : idxInRing / (countInRing - 1) - 0.5;
      const itemAngle =
        clusterCount === 1
          ? (2 * Math.PI * idx) / Math.max(1, totalItems) - Math.PI / 2
          : angle + offsetRatio * fanSpread;
      const dist =
        (clusterCount === 1 ? 165 : 108) + ring * 52 + (idx % 2) * 16;
      const nx = Math.max(70, Math.min(770, hx + Math.cos(itemAngle) * dist));
      const ny = Math.max(46, Math.min(534, hy + Math.sin(itemAngle) * dist));

      leafNodes.push({
        id: item.id,
        question: item.question,
        shortQuestion: shortLabel(item.question, 30),
        answer: item.answer,
        clusterKey: cluster.key,
        clusterLabel: cluster.label,
        palette: cluster.palette,
        raw: item,
        x: nx,
        y: ny,
      });

      edges.push({
        id: `edge-${cluster.key}-${item.id}`,
        x1: hx,
        y1: hy,
        x2: nx,
        y2: ny,
        stroke: cluster.palette.stroke,
        nodeId: item.id,
        isPrimary: false,
      });
    });
  });

  return {
    cx,
    cy,
    showCenterHub: clusterCount > 1,
    clusterNodes,
    leafNodes,
    edges,
  };
});

const selectedNode = computed(() => {
  const leaves = graphLayout.value.leafNodes;
  if (!leaves.length) return null;
  return (
    leaves.find(node => node.id === selectedNodeId.value) || leaves[0] || null
  );
});

const relatedNodes = computed(() => {
  if (!selectedNode.value) return [];
  return graphLayout.value.leafNodes
    .filter(
      node =>
        node.clusterKey === selectedNode.value.clusterKey &&
        node.id !== selectedNode.value.id
    )
    .slice(0, 6);
});

watch(
  () => props.responses,
  list => {
    if (!list?.length) {
      selectedNodeId.value = null;
      return;
    }
    if (!list.some(item => item.id === selectedNodeId.value)) {
      selectedNodeId.value = list[0].id;
    }
  },
  { immediate: true }
);

const selectCluster = key => {
  activeClusterKey.value = key;
  const firstInCluster = graphLayout.value.leafNodes[0];
  if (firstInCluster) {
    selectedNodeId.value = firstInCluster.id;
  }
};

const selectNode = id => {
  selectedNodeId.value = id;
};

const adjustZoom = delta => {
  zoom.value = Math.min(
    1.6,
    Math.max(0.75, Number((zoom.value + delta).toFixed(2)))
  );
};

const resetZoom = () => {
  zoom.value = 1;
};

const curvePath = edge => {
  const mx = (edge.x1 + edge.x2) / 2;
  const my = (edge.y1 + edge.y2) / 2 - 14;
  return `M ${edge.x1} ${edge.y1} Q ${mx} ${my} ${edge.x2} ${edge.y2}`;
};

const handleSourceClick = doc => {
  if (!doc) return;
  emit('navigate', { id: doc.id, type: doc.type });
};
</script>

<template>
  <div class="flex flex-col gap-4" data-testid="knowledge-graph-cloud">
    <!-- Topic / Cluster Cloud Pills -->
    <div
      class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-2 px-4 py-3"
    >
      <div class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium transition-colors"
          :class="
            activeClusterKey === 'all'
              ? 'border-n-brand bg-n-brand/15 text-n-brand'
              : 'border-n-weak bg-n-surface-1 text-n-slate-11 hover:text-n-slate-12'
          "
          @click="selectCluster('all')"
        >
          <Icon icon="i-lucide-network" class="size-3.5" />
          <span>{{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ALL_TOPICS') }}</span>
          <span class="rounded-full bg-n-alpha-2 px-1.5 py-0.5 text-[11px]">
            {{ responses.length }}
          </span>
        </button>

        <button
          v-for="cluster in clusters"
          :key="cluster.key"
          type="button"
          class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium transition-all"
          :class="
            activeClusterKey === cluster.key
              ? cluster.palette.chip
              : 'border-n-weak bg-n-surface-1 text-n-slate-11 hover:text-n-slate-12'
          "
          @click="selectCluster(cluster.key)"
        >
          <span
            class="size-2 rounded-full"
            :style="{ backgroundColor: cluster.palette.dot }"
          />
          <span>{{ cluster.label }}</span>
          <span class="opacity-75">{{ cluster.items.length }}</span>
        </button>
      </div>

      <span
        class="inline-flex items-center gap-1.5 rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
      >
        <Icon icon="i-lucide-lock" class="size-3" />
        {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.READ_ONLY_BADGE') }}
      </span>
    </div>

    <!-- Graph Cloud Canvas + Inspector Panel -->
    <div class="grid grid-cols-1 gap-4 lg:grid-cols-12">
      <!-- Interactive SVG Graph Cloud -->
      <div
        class="relative flex min-h-[480px] flex-col overflow-hidden rounded-2xl border border-n-weak bg-n-solid-1 lg:col-span-7"
      >
        <div
          class="flex items-center justify-between border-b border-n-weak px-4 py-2.5 text-xs text-n-slate-11"
        >
          <div class="flex items-center gap-3">
            <span>
              {{
                t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.CLUSTERS_COUNT', {
                  count: visibleClusters.length,
                })
              }}
            </span>
            <span>
              {{
                t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.NODES_COUNT', {
                  count: graphLayout.leafNodes.length,
                })
              }}
            </span>
          </div>
          <div class="flex items-center gap-1">
            <button
              type="button"
              class="rounded-md p-1 text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12"
              :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ZOOM_OUT')"
              @click="adjustZoom(-0.15)"
            >
              <Icon icon="i-lucide-minus" class="size-3.5" />
            </button>
            <button
              type="button"
              class="rounded-md px-2 py-0.5 text-xs text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12"
              :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ZOOM_RESET')"
              @click="resetZoom"
            >
              {{ `${Math.round(zoom * 100)}%` }}
            </button>
            <button
              type="button"
              class="rounded-md p-1 text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12"
              :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ZOOM_IN')"
              @click="adjustZoom(0.15)"
            >
              <Icon icon="i-lucide-plus" class="size-3.5" />
            </button>
          </div>
        </div>

        <div class="relative flex-1 overflow-auto p-2">
          <svg
            viewBox="0 0 840 580"
            class="h-full min-h-[440px] w-full origin-center select-none transition-transform duration-200"
            :style="{
              transform: `scale(${zoom})`,
            }"
          >
            <!-- Curved Edges -->
            <g>
              <path
                v-for="edge in graphLayout.edges"
                :key="edge.id"
                :d="curvePath(edge)"
                fill="none"
                :stroke="edge.stroke"
                :stroke-width="
                  selectedNode && edge.nodeId === selectedNode.id
                    ? 2.6
                    : edge.isPrimary
                      ? 1.8
                      : 1.2
                "
                :stroke-opacity="
                  selectedNode && edge.nodeId === selectedNode.id
                    ? 0.95
                    : edge.isPrimary
                      ? 0.45
                      : 0.28
                "
                stroke-linecap="round"
              />
            </g>

            <!-- Center Knowledge Hub -->
            <g
              v-if="graphLayout.showCenterHub"
              class="cursor-pointer"
              @click="selectCluster('all')"
            >
              <circle
                :cx="graphLayout.cx"
                :cy="graphLayout.cy"
                r="38"
                fill="rgba(59, 130, 246, 0.12)"
                stroke="#3b82f6"
                stroke-width="2"
              />
              <circle
                :cx="graphLayout.cx"
                :cy="graphLayout.cy"
                r="6"
                fill="#3b82f6"
              />
              <text
                :x="graphLayout.cx"
                :y="graphLayout.cy + 54"
                text-anchor="middle"
                class="fill-n-slate-12 text-[12px] font-semibold"
              >
                {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.CENTER_HUB') }}
              </text>
            </g>

            <!-- Cluster Hub Nodes -->
            <g
              v-for="cluster in graphLayout.clusterNodes"
              :key="cluster.id"
              class="cursor-pointer"
              @click="selectCluster(cluster.key)"
            >
              <circle
                :cx="cluster.x"
                :cy="cluster.y"
                r="24"
                :fill="cluster.palette.fill"
                :stroke="cluster.palette.stroke"
                stroke-width="2"
              />
              <text
                :x="cluster.x"
                :y="cluster.y + 4"
                text-anchor="middle"
                class="fill-n-slate-12 text-[11px] font-bold"
              >
                {{ cluster.count }}
              </text>
              <text
                :x="cluster.x"
                :y="cluster.y - 30"
                text-anchor="middle"
                class="fill-n-slate-12 text-[11px] font-medium"
              >
                {{ cluster.label }}
              </text>
            </g>

            <!-- FAQ Leaf Cloud Bubbles -->
            <g
              v-for="node in graphLayout.leafNodes"
              :key="node.id"
              class="cursor-pointer"
              data-testid="knowledge-graph-node"
              @click="selectNode(node.id)"
            >
              <circle
                :cx="node.x"
                :cy="node.y"
                :r="selectedNode && selectedNode.id === node.id ? 12 : 8"
                :fill="
                  selectedNode && selectedNode.id === node.id
                    ? node.palette.dot
                    : node.palette.fill
                "
                :stroke="node.palette.stroke"
                :stroke-width="
                  selectedNode && selectedNode.id === node.id ? 2.5 : 1.5
                "
              />
              <text
                :x="node.x"
                :y="node.y + 22"
                text-anchor="middle"
                class="text-[10.5px] transition-all"
                :class="
                  selectedNode && selectedNode.id === node.id
                    ? 'fill-n-slate-12 font-semibold'
                    : 'fill-n-slate-11'
                "
              >
                {{ node.shortQuestion }}
              </text>
            </g>
          </svg>
        </div>
      </div>

      <!-- Read-Only Node Inspector Panel -->
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
              class="inline-flex items-center gap-1.5 text-xs text-n-slate-11"
            >
              <Icon icon="i-lucide-file-text" class="size-3.5 shrink-0" />
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
            class="flex flex-col gap-1.5 rounded-xl border border-n-weak bg-n-surface-1 p-3.5"
          >
            <span
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ANSWER_LABEL') }}
            </span>
            <p
              class="m-0 whitespace-pre-line text-sm leading-relaxed text-n-slate-12"
            >
              {{ selectedNode.answer }}
            </p>
          </div>

          <div v-if="relatedNodes.length" class="flex flex-col gap-2 pt-1">
            <span class="text-xs font-medium text-n-slate-11">
              {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.RELATED_QUESTIONS') }}
            </span>
            <div class="flex flex-wrap gap-1.5">
              <button
                v-for="rel in relatedNodes"
                :key="rel.id"
                type="button"
                class="rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-1.5 text-left text-xs text-n-slate-11 transition-colors hover:border-n-brand/40 hover:text-n-slate-12"
                @click="selectNode(rel.id)"
              >
                {{ rel.shortQuestion }}
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
