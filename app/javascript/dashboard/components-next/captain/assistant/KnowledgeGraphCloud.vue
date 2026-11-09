<script setup>
import {
  computed,
  ref,
  shallowRef,
  watch,
  onMounted,
  onBeforeUnmount,
  nextTick,
} from 'vue';
import { useI18n } from 'vue-i18n';
import * as THREE from 'three';
import { UnrealBloomPass } from 'three/examples/jsm/postprocessing/UnrealBloomPass.js';
import SpriteText from 'three-spritetext';
import {
  forceSimulation,
  forceLink,
  forceManyBody,
  forceCollide,
  forceCenter,
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
      fill: 'rgba(16, 185, 129, 0.22)',
      chip: 'bg-n-teal-3/70 text-n-teal-11 border-n-teal-6',
      dot: '#10b981',
      emissive: '#059669',
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
      fill: 'rgba(59, 130, 246, 0.22)',
      chip: 'bg-n-blue-3/70 text-n-blue-11 border-n-blue-6',
      dot: '#3b82f6',
      emissive: '#2563eb',
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
      stroke: '#a855f7',
      fill: 'rgba(168, 85, 247, 0.22)',
      chip: 'bg-n-violet-3/70 text-n-violet-11 border-n-violet-6',
      dot: '#a855f7',
      emissive: '#7e22ce',
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
      fill: 'rgba(245, 158, 11, 0.22)',
      chip: 'bg-n-amber-3/70 text-n-amber-11 border-n-amber-6',
      dot: '#f59e0b',
      emissive: '#d97706',
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
      fill: 'rgba(236, 72, 153, 0.22)',
      chip: 'bg-n-ruby-3/70 text-n-ruby-11 border-n-ruby-6',
      dot: '#ec4899',
      emissive: '#db2777',
    },
  },
];

const DEFAULT_CLUSTER = {
  key: 'general',
  i18nKey: 'GENERAL',
  icon: 'i-lucide-sparkles',
  palette: {
    stroke: '#06b6d4',
    fill: 'rgba(6, 182, 212, 0.22)',
    chip: 'bg-n-slate-3 text-n-slate-12 border-n-slate-6',
    dot: '#06b6d4',
    emissive: '#0891b2',
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
  const haystack = `${item?.question || ''} ${item?.answer || ''} ${item?.documentable?.name || ''}`.toLowerCase();
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
const autoOrbit = ref(true);
const bloomEnabled = ref(true);
const webglReady = ref(false);

const stageContainerRef = ref(null);
const graph3dInstance = shallowRef(null);
const bloomPassRef = shallowRef(null);
const orbitAngleRef = ref(0);
const orbitRafRef = ref(null);
const resizeObserverRef = shallowRef(null);

const simNodes = ref([]);
const simEdges = ref([]);

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
      shortQuestion: truncateText(question, 34),
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

const buildGraphTopology = () => {
  const items = visibleItems.value;
  if (!items.length) {
    simNodes.value = [];
    simEdges.value = [];
    return { nodes: [], links: [] };
  }

  const nodes = [];
  const links = [];

  const showCore = activeClusterKey.value === 'all' && clusters.value.length > 1;
  if (showCore) {
    nodes.push({
      id: 'core-hub',
      kind: 'core',
      label: t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.CENTER_HUB'),
      radius: 26,
      val: 34,
      x: CENTER_X,
      y: CENTER_Y,
      z: 0,
      fx: 0,
      fy: 0,
      fz: 0,
      palette: {
        stroke: '#38bdf8',
        fill: 'rgba(56, 189, 248, 0.25)',
        dot: '#38bdf8',
        emissive: '#0284c7',
      },
      degree: clusters.value.length,
    });
  }

  const activeClusters =
    activeClusterKey.value === 'all'
      ? clusters.value
      : clusters.value.filter(c => c.key === activeClusterKey.value);

  const clusterAnchors = new Map();
  activeClusters.forEach((cluster, idx) => {
    const angle =
      (idx / Math.max(activeClusters.length, 1)) * Math.PI * 2 - Math.PI / 2;
    const orbit = showCore ? 160 : 0;
    const cx = CENTER_X + Math.cos(angle) * orbit;
    const cy = CENTER_Y + Math.sin(angle) * orbit;
    const cz = ((idx % 3) - 1) * 48;
    const clusterNodeId = `cluster-${cluster.key}`;
    clusterAnchors.set(cluster.key, {
      x: cx,
      y: cy,
      z: cz,
      angle,
      id: clusterNodeId,
    });

    nodes.push({
      id: clusterNodeId,
      kind: 'cluster',
      clusterKey: cluster.key,
      label: `${cluster.label} (${cluster.count})`,
      shortLabel: cluster.label,
      count: cluster.count,
      radius: Math.min(22, 15 + Math.sqrt(cluster.count) * 2),
      val: 18 + cluster.count * 1.5,
      x: cx,
      y: cy,
      z: cz,
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
        distance: 135,
        strength: 0.85,
      });
    }
  });

  items.forEach((item, idx) => {
    const anchor = clusterAnchors.get(item.clusterKey) || {
      x: CENTER_X,
      y: CENTER_Y,
      z: 0,
      angle: 0,
      id: `cluster-${item.clusterKey}`,
    };
    const spreadAngle =
      anchor.angle + ((idx % 9) - 4) * 0.25 + (idx * 0.61803398875) % 0.5;
    const dist = 80 + (idx % 4) * 28;

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
      radius: 8.5,
      val: 7,
      degree: 1,
      x: anchor.x + Math.cos(spreadAngle) * dist,
      y: anchor.y + Math.sin(spreadAngle) * dist,
      z: anchor.z + ((idx % 5) - 2) * 32,
    });

    links.push({
      id: `link-${anchor.id}-${item.id}`,
      source: anchor.id,
      target: item.id,
      kind: 'topic',
      stroke: item.palette.stroke,
      distance: 78 + (idx % 3) * 16,
      strength: 0.7,
    });
  });

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
        distance: 95,
        strength: 0.25,
      });
      degreeCounter.set(items[i].id, (degreeCounter.get(items[i].id) || 1) + 1);
      degreeCounter.set(bestPeer.id, (degreeCounter.get(bestPeer.id) || 1) + 1);
    }
  }

  nodes.forEach(n => {
    if (n.kind === 'faq') {
      const deg = degreeCounter.get(n.id) || 1;
      n.degree = deg;
      n.radius = Math.min(13.5, 7 + deg * 1.4);
      n.val = 5 + deg * 2.2;
    }
  });

  // Settled 2D layout for instant fallback & deterministic tests
  const sim2dNodes = nodes.map(n => ({ ...n, fx: undefined, fy: undefined }));
  const sim2dLinks = links.map(l => ({ ...l }));
  const sim = forceSimulation(sim2dNodes)
    .force(
      'link',
      forceLink(sim2dLinks)
        .id(d => d.id)
        .distance(d => d.distance || 90)
    )
    .force('charge', forceManyBody().strength(-180))
    .force('collide', forceCollide().radius(d => d.radius + 14))
    .force('center', forceCenter(CENTER_X, CENTER_Y))
    .stop();
  sim.tick(90);

  simNodes.value = sim2dNodes.map(n => ({
    ...n,
    x: Math.max(48, Math.min(VIEWPORT_WIDTH - 48, n.x || CENTER_X)),
    y: Math.max(42, Math.min(VIEWPORT_HEIGHT - 42, n.y || CENTER_Y)),
  }));
  simEdges.value = sim2dLinks.map(l => ({
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

  // Return fresh 3D graph objects centered at (0,0,0) for Three.js ForceGraph3D
  const nodes3d = nodes.map(n => ({
    ...n,
    x: (n.x - CENTER_X) * 0.7,
    y: (n.y - CENTER_Y) * 0.7,
    z: n.z || 0,
  }));
  const links3d = links.map(l => ({
    ...l,
    source: typeof l.source === 'object' ? l.source.id : l.source,
    target: typeof l.target === 'object' ? l.target.id : l.target,
  }));

  return { nodes: nodes3d, links: links3d };
};

const buildNodeThreeObject = node => {
  const group = new THREE.Group();
  const isSelected =
    node.kind === 'faq' && selectedNode.value?.rawId === node.rawId;

  const baseRadius =
    node.kind === 'core'
      ? 13
      : node.kind === 'cluster'
        ? 8.5
        : isSelected
          ? 5.8
          : 4.2;

  const sphereGeo = new THREE.SphereGeometry(baseRadius, 28, 28);
  const sphereMat = new THREE.MeshStandardMaterial({
    color: new THREE.Color(isSelected ? '#ffffff' : node.palette.dot),
    emissive: new THREE.Color(node.palette.dot),
    emissiveIntensity:
      node.kind === 'core'
        ? 1.4
        : node.kind === 'cluster'
          ? 1.05
          : isSelected
            ? 1.5
            : 0.75,
    roughness: 0.18,
    metalness: 0.35,
  });
  const sphereMesh = new THREE.Mesh(sphereGeo, sphereMat);
  group.add(sphereMesh);

  // Outer translucent energy halo for core, clusters, and selected FAQ node
  if (node.kind === 'core' || node.kind === 'cluster' || isSelected) {
    const haloGeo = new THREE.SphereGeometry(baseRadius * 1.55, 24, 24);
    const haloMat = new THREE.MeshBasicMaterial({
      color: new THREE.Color(node.palette.dot),
      transparent: true,
      opacity: isSelected ? 0.28 : 0.16,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    group.add(new THREE.Mesh(haloGeo, haloMat));
  }

  // Orbital ring around Core Hub
  if (node.kind === 'core') {
    const ringGeo = new THREE.TorusGeometry(baseRadius * 1.9, 0.45, 16, 64);
    const ringMat = new THREE.MeshBasicMaterial({
      color: new THREE.Color('#38bdf8'),
      transparent: true,
      opacity: 0.55,
      blending: THREE.AdditiveBlending,
    });
    const ringMesh = new THREE.Mesh(ringGeo, ringMat);
    ringMesh.rotation.x = Math.PI / 2.6;
    group.add(ringMesh);
  }

  // Crisp 3D billboard text sprite below sphere
  const sprite = new SpriteText(node.label || '');
  sprite.color =
    node.kind === 'core'
      ? '#f8fafc'
      : node.kind === 'cluster'
        ? '#f1f5f9'
        : isSelected
          ? '#ffffff'
          : '#cbd5e1';
  sprite.textHeight =
    node.kind === 'core'
      ? 5.2
      : node.kind === 'cluster'
        ? 4.2
        : isSelected
          ? 3.6
          : 2.9;
  sprite.fontWeight =
    node.kind === 'faq' && !isSelected ? '500' : '700';
  sprite.fontFace = 'Inter, system-ui, -apple-system, sans-serif';
  sprite.backgroundColor =
    node.kind !== 'faq' || isSelected
      ? 'rgba(15, 23, 42, 0.82)'
      : 'rgba(15, 23, 42, 0.48)';
  sprite.padding = node.kind !== 'faq' || isSelected ? 2.2 : 1.4;
  sprite.borderRadius = 4;
  if (isSelected || node.kind === 'cluster') {
    sprite.borderWidth = 0.5;
    sprite.borderColor = node.palette.dot;
  }
  sprite.position.set(0, -(baseRadius + 6.5), 0);
  group.add(sprite);

  return group;
};

const addStarfieldToScene = scene => {
  if (!scene || scene.getObjectByName('onelink-starfield')) return;
  const starCount = 420;
  const positions = new Float32Array(starCount * 3);
  const colors = new Float32Array(starCount * 3);
  const palette = [
    new THREE.Color('#38bdf8'),
    new THREE.Color('#818cf8'),
    new THREE.Color('#c084fc'),
    new THREE.Color('#34d399'),
  ];

  for (let i = 0; i < starCount; i += 1) {
    const r = 280 + Math.random() * 520;
    const theta = Math.random() * Math.PI * 2;
    const phi = Math.acos(2 * Math.random() - 1);
    positions[i * 3] = r * Math.sin(phi) * Math.cos(theta);
    positions[i * 3 + 1] = r * Math.sin(phi) * Math.sin(theta);
    positions[i * 3 + 2] = r * Math.cos(phi);

    const c = palette[i % palette.length];
    colors[i * 3] = c.r;
    colors[i * 3 + 1] = c.g;
    colors[i * 3 + 2] = c.b;
  }

  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  geo.setAttribute('color', new THREE.BufferAttribute(colors, 3));

  const mat = new THREE.PointsMaterial({
    size: 2.1,
    vertexColors: true,
    transparent: true,
    opacity: 0.55,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
  });

  const stars = new THREE.Points(geo, mat);
  stars.name = 'onelink-starfield';
  scene.add(stars);

  const ambient = new THREE.AmbientLight(0xffffff, 1.35);
  ambient.name = 'onelink-ambient';
  scene.add(ambient);

  const pointLight = new THREE.PointLight(0x60a5fa, 2.8, 900);
  pointLight.position.set(80, 120, 160);
  scene.add(pointLight);
};

const flyToNode3D = node => {
  const fg = graph3dInstance.value;
  if (!fg || !node || typeof node.x !== 'number') return;
  autoOrbit.value = false;
  const distance = 135;
  const distRatio =
    1 + distance / Math.hypot(node.x || 1, node.y || 1, node.z || 1);
  fg.cameraPosition(
    {
      x: (node.x || 0) * distRatio,
      y: (node.y || 0) * distRatio,
      z: (node.z || 0) * distRatio + 20,
    },
    { x: node.x || 0, y: node.y || 0, z: node.z || 0 },
    1150
  );
};

const resetCamera3D = () => {
  const fg = graph3dInstance.value;
  if (!fg) return;
  fg.cameraPosition(
    { x: 0, y: 35, z: 360 },
    { x: 0, y: 0, z: 0 },
    950
  );
};

const zoomCamera3D = factor => {
  const fg = graph3dInstance.value;
  if (!fg) return;
  autoOrbit.value = false;
  const cam = fg.camera();
  if (!cam) return;
  fg.cameraPosition(
    {
      x: cam.position.x * factor,
      y: cam.position.y * factor,
      z: cam.position.z * factor,
    },
    { x: 0, y: 0, z: 0 },
    420
  );
};

const refresh3DAppearance = () => {
  const fg = graph3dInstance.value;
  if (!fg) return;
  fg.nodeThreeObject(node => buildNodeThreeObject(node));
};

const startOrbitLoop = () => {
  if (orbitRafRef.value) cancelAnimationFrame(orbitRafRef.value);
  const step = () => {
    const fg = graph3dInstance.value;
    if (fg && autoOrbit.value && !hoveredNodeId.value) {
      orbitAngleRef.value += 0.0022;
      const radius = 355;
      fg.cameraPosition({
        x: radius * Math.sin(orbitAngleRef.value),
        y: 32 * Math.sin(orbitAngleRef.value * 0.6),
        z: radius * Math.cos(orbitAngleRef.value),
      });
    }
    orbitRafRef.value = requestAnimationFrame(step);
  };
  orbitRafRef.value = requestAnimationFrame(step);
};

const init3DForceEngine = async () => {
  if (typeof window === 'undefined' || !stageContainerRef.value) return;
  // Skip WebGL boot inside headless jsdom unit tests
  if (
    typeof navigator !== 'undefined' &&
    /jsdom/i.test(navigator.userAgent || '')
  ) {
    return;
  }

  try {
    const mod = await import('3d-force-graph');
    const ForceGraph3D = mod.default || mod;
    const container = stageContainerRef.value;
    if (!container) return;

    const topology = buildGraphTopology();
    const width = container.clientWidth || 720;
    const height = container.clientHeight || 540;

    const fg = ForceGraph3D({ controlType: 'orbit' })(container)
      .width(width)
      .height(height)
      .backgroundColor('#060913')
      .showNavInfo(false)
      .graphData(topology)
      .nodeId('id')
      .nodeVal('val')
      .nodeThreeObject(node => buildNodeThreeObject(node))
      .linkColor(link => link.stroke || '#38bdf8')
      .linkOpacity(0.42)
      .linkWidth(link => {
        if (link.kind === 'backbone') return 1.8;
        if (link.kind === 'semantic') return 0.9;
        return 1.25;
      })
      .linkCurvature(link => (link.kind === 'semantic' ? 0.28 : 0.12))
      .linkDirectionalParticles(link => {
        if (link.kind === 'backbone') return 3;
        if (link.kind === 'semantic') return 2;
        return 1;
      })
      .linkDirectionalParticleWidth(2.4)
      .linkDirectionalParticleSpeed(0.0055)
      .linkDirectionalParticleColor(link => link.stroke || '#38bdf8')
      .onNodeHover(node => {
        hoveredNodeId.value = node ? node.id : null;
        if (container) {
          container.style.cursor = node ? 'pointer' : 'grab';
        }
      })
      .onNodeClick(node => {
        if (!node) return;
        if (node.kind === 'core') {
          selectCluster('all');
          resetCamera3D();
          return;
        }
        if (node.kind === 'cluster') {
          selectCluster(node.clusterKey);
          return;
        }
        if (node.kind === 'faq') {
          selectedNodeId.value = node.rawId;
          refresh3DAppearance();
          flyToNode3D(node);
        }
      })
      .onNodeDrag(() => {
        autoOrbit.value = false;
      });

    // Tune 3D force distances
    const linkForce = fg.d3Force('link');
    if (linkForce) {
      linkForce.distance(link => link.distance || 85);
    }
    const chargeForce = fg.d3Force('charge');
    if (chargeForce) {
      chargeForce.strength(node => {
        if (node.kind === 'core') return -420;
        if (node.kind === 'cluster') return -260;
        return -110;
      });
    }

    // Add UnrealBloomPass for neon glow
    try {
      const composer = fg.postProcessingComposer();
      const bloomPass = new UnrealBloomPass(
        new THREE.Vector2(width, height),
        1.15,
        0.45,
        0.18
      );
      composer.addPass(bloomPass);
      bloomPassRef.value = bloomPass;
    } catch {
      // Fallback if postprocessing composer unavailable
    }

    addStarfieldToScene(fg.scene());
    fg.cameraPosition({ x: 0, y: 35, z: 360 });

    // Stop auto-orbit when user manually interacts with canvas
    const domElem = fg.renderer()?.domElement;
    if (domElem) {
      domElem.addEventListener(
        'pointerdown',
        () => {
          autoOrbit.value = false;
        },
        { passive: true }
      );
      domElem.addEventListener(
        'wheel',
        () => {
          autoOrbit.value = false;
        },
        { passive: true }
      );
    }

    if (typeof ResizeObserver !== 'undefined') {
      const ro = new ResizeObserver(entries => {
        for (const entry of entries) {
          const { width: w, height: h } = entry.contentRect;
          if (w > 0 && h > 0 && graph3dInstance.value) {
            graph3dInstance.value.width(w).height(h);
          }
        }
      });
      ro.observe(container);
      resizeObserverRef.value = ro;
    }

    graph3dInstance.value = fg;
    webglReady.value = true;
    startOrbitLoop();
  } catch {
    webglReady.value = false;
  }
};

watch(
  [visibleItems, activeClusterKey],
  () => {
    const topology = buildGraphTopology();
    const faqList = simNodes.value.filter(n => n.kind === 'faq');
    if (
      !faqList.some(n => n.rawId === selectedNodeId.value) &&
      faqList.length > 0
    ) {
      selectedNodeId.value = faqList[0].rawId;
    }
    if (graph3dInstance.value) {
      graph3dInstance.value.graphData(topology);
      nextTick(() => {
        refresh3DAppearance();
      });
    }
  },
  { immediate: true }
);

watch(bloomEnabled, enabled => {
  if (bloomPassRef.value) {
    bloomPassRef.value.strength = enabled ? 1.15 : 0;
  }
});

onMounted(() => {
  init3DForceEngine();
});

onBeforeUnmount(() => {
  if (orbitRafRef.value) {
    cancelAnimationFrame(orbitRafRef.value);
  }
  if (resizeObserverRef.value) {
    resizeObserverRef.value.disconnect();
  }
  if (graph3dInstance.value?._destructor) {
    graph3dInstance.value._destructor();
  }
});

const faqNodes = computed(() => simNodes.value.filter(n => n.kind === 'faq'));

const selectedNode = computed(() => {
  if (!faqNodes.value.length) return null;
  return (
    faqNodes.value.find(node => node.rawId === selectedNodeId.value) ||
    faqNodes.value[0]
  );
});

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

const selectCluster = key => {
  activeClusterKey.value = key;
  if (graph3dInstance.value) {
    resetCamera3D();
  }
};

const selectNode = rawId => {
  selectedNodeId.value = rawId;
  if (graph3dInstance.value) {
    refresh3DAppearance();
    const gData = graph3dInstance.value.graphData();
    const target3d = gData?.nodes?.find(n => n.rawId === rawId);
    if (target3d) {
      flyToNode3D(target3d);
    }
  }
};

const reheatPhysics = () => {
  if (graph3dInstance.value) {
    graph3dInstance.value.d3ReheatSimulation();
  }
};

const flyToSelectedNode = () => {
  if (!selectedNode.value || !graph3dInstance.value) return;
  const gData = graph3dInstance.value.graphData();
  const target3d = gData?.nodes?.find(
    n => n.rawId === selectedNode.value.rawId
  );
  if (target3d) {
    flyToNode3D(target3d);
  }
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
    <!-- Top Topic Filter Bar & 3D WebGL Engine Status -->
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

      <div class="flex flex-wrap items-center gap-2">
        <span
          class="inline-flex items-center gap-1.5 rounded-lg border border-n-violet-6/60 bg-n-violet-3/40 px-2.5 py-1 text-[11px] font-semibold text-n-violet-11"
        >
          <Icon icon="i-lucide-sparkles" class="size-3.5" />
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

    <!-- Main Split View: 3D WebGL Galaxy Stage + Read-Only Inspector -->
    <div class="grid grid-cols-1 gap-4 lg:grid-cols-12">
      <!-- 3D WebGL Force Graph Stage -->
      <div
        class="relative flex flex-col overflow-hidden rounded-2xl border border-n-weak bg-[#060913] shadow-xl lg:col-span-7"
      >
        <!-- Top Translucent 3D Telemetry & Camera Toolbar -->
        <div
          class="z-10 flex flex-wrap items-center justify-between gap-2 border-b border-white/10 bg-slate-950/80 px-4 py-2.5 text-xs text-slate-300 backdrop-blur-md"
        >
          <div class="flex flex-wrap items-center gap-3">
            <span class="inline-flex items-center gap-1.5 font-semibold text-white">
              <Icon icon="i-lucide-box" class="size-3.5 text-sky-400" />
              {{
                t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.NODES_COUNT', {
                  count: faqNodes.length,
                })
              }}
            </span>
            <span class="text-slate-600">•</span>
            <span>
              {{
                t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.EDGES_COUNT', {
                  count: simEdges.length,
                })
              }}
            </span>
            <template v-if="documentSourcesCount > 0">
              <span class="text-slate-600">•</span>
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
            <button
              type="button"
              class="inline-flex items-center gap-1.5 rounded-lg border px-2.5 py-1 text-[11px] font-medium transition-all"
              :class="
                autoOrbit
                  ? 'border-sky-500/60 bg-sky-500/20 text-sky-300'
                  : 'border-white/10 bg-white/5 text-slate-400 hover:text-white'
              "
              :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.AUTO_ORBIT')"
              @click="autoOrbit = !autoOrbit"
            >
              <Icon icon="i-lucide-rotate-3d" class="size-3.5" />
              <span class="hidden sm:inline">{{ t('CAPTAIN.RESPONSES.GRAPH.AUTO_ORBIT') }}</span>
            </button>

            <button
              type="button"
              class="inline-flex items-center gap-1.5 rounded-lg border px-2.5 py-1 text-[11px] font-medium transition-all"
              :class="
                bloomEnabled
                  ? 'border-purple-500/60 bg-purple-500/20 text-purple-300'
                  : 'border-white/10 bg-white/5 text-slate-400 hover:text-white'
              "
              :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.BLOOM_GLOW')"
              @click="bloomEnabled = !bloomEnabled"
            >
              <Icon icon="i-lucide-sparkles" class="size-3.5" />
              <span class="hidden sm:inline">{{ t('CAPTAIN.RESPONSES.GRAPH.BLOOM_GLOW') }}</span>
            </button>

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
              @click="zoomCamera3D(1.22)"
            />
            <Button
              icon="i-lucide-compass"
              size="xs"
              variant="ghost"
              color="slate"
              :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.RESET_3D_CAMERA')"
              @click="resetCamera3D"
            />
            <Button
              icon="i-lucide-zoom-in"
              size="xs"
              variant="ghost"
              color="slate"
              :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ZOOM_IN')"
              @click="zoomCamera3D(0.8)"
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

        <!-- 3D WebGL Canvas Mount + Accessible Node Overlay for Keyboard/Test Navigation -->
        <div
          class="relative w-full overflow-hidden bg-[#060913]"
          :class="isFullscreen ? 'h-[calc(100vh-14rem)]' : 'h-[560px]'"
        >
          <div
            ref="stageContainerRef"
            class="h-full w-full"
            data-testid="knowledge-3d-webgl-canvas"
          />

          <!-- Accessible / Fallback Semantic Node Hooks (kept in DOM for screen readers & deterministic unit specs) -->
          <div
            class="sr-only"
            aria-hidden="false"
          >
            <button
              v-for="node in faqNodes"
              :key="node.id"
              type="button"
              data-testid="knowledge-graph-node"
              @click="selectNode(node.rawId)"
            >
              {{ node.label }}
            </button>
          </div>

          <!-- Bottom Floating 3D Navigation Pill -->
          <div
            class="pointer-events-none absolute bottom-3 left-3 right-3 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-white/10 bg-slate-950/75 px-3.5 py-2 text-[11px] text-slate-300 backdrop-blur-md"
          >
            <div class="flex items-center gap-2">
              <Icon icon="i-lucide-orbit" class="size-3.5 text-sky-400 shrink-0" />
              <span>{{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.DRAG_HINT') }}</span>
            </div>
            <span
              v-if="selectedNode"
              class="hidden items-center gap-1.5 text-sky-300 sm:inline-flex"
            >
              <span
                class="size-2 rounded-full"
                :style="{ backgroundColor: selectedNode.palette.dot }"
              />
              {{ selectedNode.label }}
            </span>
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

            <div class="flex items-center gap-2">
              <button
                v-if="webglReady"
                type="button"
                class="inline-flex items-center gap-1 rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-1 text-xs text-n-slate-11 transition-colors hover:border-n-brand hover:text-n-slate-12"
                @click="flyToSelectedNode"
              >
                <Icon icon="i-lucide-focus" class="size-3.5 text-n-brand" />
                <span>{{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.FLY_TO_NODE') }}</span>
              </button>

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
                  class="max-w-44 truncate"
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
