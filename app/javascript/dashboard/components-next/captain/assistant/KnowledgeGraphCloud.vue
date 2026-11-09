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

const detectDarkMode = () => {
  if (typeof document === 'undefined') return false;
  return (
    document.body?.classList.contains('dark') ||
    document.documentElement?.classList.contains('dark')
  );
};

const activeClusterKey = ref('all');
const selectedNodeId = ref(null);
const inspectorOpen = ref(true);
const hoveredNodeId = ref(null);
const isFullscreen = ref(false);
const copiedAnswer = ref(false);
const autoOrbit = ref(true);
const bloomEnabled = ref(true);
const webglReady = ref(false);
const isDarkTheme = ref(detectDarkMode());

const stageContainerRef = ref(null);
const graph3dInstance = shallowRef(null);
const bloomPassRef = shallowRef(null);
const starfieldRef = shallowRef(null);
const orbitAngleRef = ref(0);
const orbitRafRef = ref(null);
const resizeObserverRef = shallowRef(null);
const themeObserverRef = shallowRef(null);

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
  const dark = isDarkTheme.value;
  const isSelected =
    node.kind === 'faq' &&
    inspectorOpen.value &&
    selectedNode.value?.rawId === node.rawId;

  const baseRadius =
    node.kind === 'core'
      ? 13.5
      : node.kind === 'cluster'
        ? 9
        : isSelected
          ? 6.2
          : 4.5;

  const sphereGeo = new THREE.SphereGeometry(baseRadius, 28, 28);
  const sphereMat = new THREE.MeshStandardMaterial({
    color: new THREE.Color(
      isSelected && dark ? '#ffffff' : node.palette.dot
    ),
    emissive: new THREE.Color(node.palette.dot),
    emissiveIntensity: dark
      ? node.kind === 'core'
        ? 1.35
        : node.kind === 'cluster'
          ? 1.0
          : isSelected
            ? 1.45
            : 0.72
      : isSelected
        ? 0.42
        : 0.2,
    roughness: dark ? 0.18 : 0.22,
    metalness: dark ? 0.35 : 0.12,
  });
  const sphereMesh = new THREE.Mesh(sphereGeo, sphereMat);
  group.add(sphereMesh);

  // Outer translucent energy halo for core, clusters, and selected FAQ node
  if (node.kind === 'core' || node.kind === 'cluster' || isSelected) {
    const haloGeo = new THREE.SphereGeometry(baseRadius * 1.55, 24, 24);
    const haloMat = new THREE.MeshBasicMaterial({
      color: new THREE.Color(node.palette.dot),
      transparent: true,
      opacity: dark ? (isSelected ? 0.28 : 0.16) : isSelected ? 0.22 : 0.12,
      blending: dark ? THREE.AdditiveBlending : THREE.NormalBlending,
      depthWrite: false,
    });
    group.add(new THREE.Mesh(haloGeo, haloMat));
  }

  // Orbital ring around Core Hub
  if (node.kind === 'core') {
    const ringGeo = new THREE.TorusGeometry(baseRadius * 1.9, 0.45, 16, 64);
    const ringMat = new THREE.MeshBasicMaterial({
      color: new THREE.Color(dark ? '#38bdf8' : '#0284c7'),
      transparent: true,
      opacity: dark ? 0.55 : 0.35,
      blending: dark ? THREE.AdditiveBlending : THREE.NormalBlending,
    });
    const ringMesh = new THREE.Mesh(ringGeo, ringMat);
    ringMesh.rotation.x = Math.PI / 2.6;
    group.add(ringMesh);
  }

  // Crisp 3D billboard text sprite below sphere
  const sprite = new SpriteText(node.label || '');
  if (dark) {
    sprite.color =
      node.kind === 'core'
        ? '#f8fafc'
        : node.kind === 'cluster'
          ? '#f1f5f9'
          : isSelected
            ? '#ffffff'
            : '#cbd5e1';
    sprite.backgroundColor =
      node.kind !== 'faq' || isSelected
        ? 'rgba(15, 23, 42, 0.84)'
        : 'rgba(15, 23, 42, 0.52)';
  } else {
    sprite.color =
      node.kind === 'core' || node.kind === 'cluster' || isSelected
        ? '#0f172a'
        : '#334155';
    sprite.backgroundColor =
      node.kind !== 'faq' || isSelected
        ? 'rgba(255, 255, 255, 0.94)'
        : 'rgba(248, 250, 252, 0.84)';
  }
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
  sprite.padding = node.kind !== 'faq' || isSelected ? 2.2 : 1.4;
  sprite.borderRadius = 4;
  if (isSelected || node.kind === 'cluster' || !dark) {
    sprite.borderWidth = isSelected || node.kind === 'cluster' ? 0.55 : 0.3;
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
  stars.visible = isDarkTheme.value;
  scene.add(stars);
  starfieldRef.value = stars;

  const ambient = new THREE.AmbientLight(0xffffff, 1.55);
  ambient.name = 'onelink-ambient';
  scene.add(ambient);

  const pointLight = new THREE.PointLight(0x60a5fa, 2.6, 950);
  pointLight.position.set(90, 140, 180);
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
      y: (node.y || 0) * distRatio + 16,
      z: (node.z || 0) * distRatio,
    },
    { x: node.x || 0, y: node.y || 0, z: node.z || 0 },
    1050
  );
};

const resetCamera3D = () => {
  const fg = graph3dInstance.value;
  if (!fg) return;
  fg.cameraPosition({ x: 0, y: 32, z: 340 }, { x: 0, y: 0, z: 0 }, 900);
};

const zoomCamera3D = factor => {
  const fg = graph3dInstance.value;
  if (!fg) return;
  autoOrbit.value = false;
  const pos = fg.cameraPosition();
  if (!pos) return;
  fg.cameraPosition(
    {
      x: pos.x * factor,
      y: pos.y * factor,
      z: pos.z * factor,
    },
    { x: 0, y: 0, z: 0 },
    380
  );
};

const refresh3DAppearance = () => {
  const fg = graph3dInstance.value;
  if (!fg) return;
  fg.nodeThreeObject(node => buildNodeThreeObject(node));
};

const applyThemeTo3D = () => {
  const fg = graph3dInstance.value;
  const dark = isDarkTheme.value;
  if (fg) {
    fg.backgroundColor(dark ? '#050814' : '#ffffff');
    fg.linkOpacity(dark ? 0.42 : 0.55);
  }
  if (bloomPassRef.value) {
    bloomPassRef.value.strength = dark && bloomEnabled.value ? 1.1 : 0;
  }
  if (starfieldRef.value) {
    starfieldRef.value.visible = dark;
  }
  refresh3DAppearance();
};

const startOrbitLoop = () => {
  if (orbitRafRef.value) cancelAnimationFrame(orbitRafRef.value);
  const step = () => {
    const fg = graph3dInstance.value;
    if (fg && autoOrbit.value && !hoveredNodeId.value) {
      orbitAngleRef.value += 0.002;
      const radius = 340;
      fg.cameraPosition({
        x: radius * Math.sin(orbitAngleRef.value),
        y: 28 * Math.sin(orbitAngleRef.value * 0.6),
        z: radius * Math.cos(orbitAngleRef.value),
      });
    }
    orbitRafRef.value = requestAnimationFrame(step);
  };
  orbitRafRef.value = requestAnimationFrame(step);
};

const init3DForceEngine = async () => {
  if (typeof window === 'undefined' || !stageContainerRef.value) return;
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

    isDarkTheme.value = detectDarkMode();
    const dark = isDarkTheme.value;
    const topology = buildGraphTopology();
    const width = container.clientWidth || 960;
    const height = container.clientHeight || 680;

    const fg = ForceGraph3D({ controlType: 'orbit' })(container)
      .width(width)
      .height(height)
      .backgroundColor(dark ? '#050814' : '#ffffff')
      .showNavInfo(false)
      .graphData(topology)
      .nodeId('id')
      .nodeVal('val')
      .nodeThreeObject(node => buildNodeThreeObject(node))
      .linkColor(link => link.stroke || '#3b82f6')
      .linkOpacity(dark ? 0.42 : 0.55)
      .linkWidth(link => {
        if (link.kind === 'backbone') return 1.8;
        if (link.kind === 'semantic') return 0.95;
        return 1.3;
      })
      .linkCurvature(link => (link.kind === 'semantic' ? 0.28 : 0.12))
      .linkDirectionalParticles(link => {
        if (link.kind === 'backbone') return 3;
        if (link.kind === 'semantic') return 2;
        return 1;
      })
      .linkDirectionalParticleWidth(2.4)
      .linkDirectionalParticleSpeed(0.0055)
      .linkDirectionalParticleColor(link => link.stroke || '#3b82f6')
      .onNodeHover(node => {
        hoveredNodeId.value = node ? node.id : null;
        if (container) {
          container.style.cursor = node ? 'pointer' : 'grab';
        }
      })
      .onBackgroundClick(() => {
        inspectorOpen.value = false;
        refresh3DAppearance();
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
          inspectorOpen.value = true;
          refresh3DAppearance();
          flyToNode3D(node);
        }
      })
      .onNodeDrag(() => {
        autoOrbit.value = false;
      });

    const linkForce = fg.d3Force('link');
    if (linkForce) {
      linkForce.distance(link => link.distance || 85);
    }
    const chargeForce = fg.d3Force('charge');
    if (chargeForce) {
      chargeForce.strength(node => {
        if (node.kind === 'core') return -420;
        if (node.kind === 'cluster') return -260;
        return -115;
      });
    }

    try {
      const composer = fg.postProcessingComposer();
      const bloomPass = new UnrealBloomPass(
        new THREE.Vector2(width, height),
        dark && bloomEnabled.value ? 1.1 : 0,
        0.45,
        0.18
      );
      composer.addPass(bloomPass);
      bloomPassRef.value = bloomPass;
    } catch {
      // Ignore if postprocessing unavailable
    }

    addStarfieldToScene(fg.scene());
    fg.cameraPosition({ x: 0, y: 32, z: 340 });

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
        entries.forEach(entry => {
          const { width: w, height: h } = entry.contentRect;
          if (w > 0 && h > 0 && graph3dInstance.value) {
            graph3dInstance.value.width(w).height(h);
          }
        });
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
    bloomPassRef.value.strength = isDarkTheme.value && enabled ? 1.1 : 0;
  }
});

watch(isDarkTheme, () => {
  applyThemeTo3D();
});

onMounted(() => {
  isDarkTheme.value = detectDarkMode();
  if (typeof MutationObserver !== 'undefined' && typeof document !== 'undefined') {
    const mo = new MutationObserver(() => {
      const nextDark = detectDarkMode();
      if (nextDark !== isDarkTheme.value) {
        isDarkTheme.value = nextDark;
      }
    });
    if (document.body) {
      mo.observe(document.body, { attributes: true, attributeFilter: ['class'] });
    }
    if (document.documentElement) {
      mo.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ['class'],
      });
    }
    themeObserverRef.value = mo;
  }
  init3DForceEngine();
});

onBeforeUnmount(() => {
  if (orbitRafRef.value) {
    cancelAnimationFrame(orbitRafRef.value);
  }
  if (resizeObserverRef.value) {
    resizeObserverRef.value.disconnect();
  }
  if (themeObserverRef.value) {
    themeObserverRef.value.disconnect();
  }
  if (graph3dInstance.value) {
    const destructor = graph3dInstance.value._destructor;
    if (typeof destructor === 'function') {
      destructor.call(graph3dInstance.value);
    }
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
  inspectorOpen.value = true;
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
    class="relative w-full overflow-hidden transition-colors"
    :class="[
      isDarkTheme ? 'bg-[#050814]' : 'bg-white',
      isFullscreen
        ? 'fixed inset-0 z-50 h-screen w-screen'
        : 'h-[calc(100vh-3.5rem)] min-h-[640px]',
    ]"
  >
    <!-- Full-Bleed 3D WebGL Canvas -->
    <div
      ref="stageContainerRef"
      class="h-full w-full"
      data-testid="knowledge-3d-webgl-canvas"
    />

    <!-- Accessible Semantic Node Hooks (kept in DOM for screen readers & deterministic unit specs) -->
    <div class="sr-only" aria-hidden="false">
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

    <!-- Top-Left Floating Topic Filter Pills (Minimal, No Noise) -->
    <div
      v-if="clusters.length > 1"
      class="pointer-events-auto absolute left-4 top-4 z-10 flex max-w-[calc(100%-14rem)] flex-wrap items-center gap-1.5"
    >
      <button
        type="button"
        class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium shadow-sm backdrop-blur-md transition-all"
        :class="
          activeClusterKey === 'all'
            ? 'border-n-brand bg-n-brand text-white'
            : isDarkTheme
              ? 'border-white/10 bg-slate-900/75 text-slate-300 hover:text-white'
              : 'border-slate-200/90 bg-white/90 text-slate-700 hover:border-slate-300 hover:text-slate-950'
        "
        @click="selectCluster('all')"
      >
        <span>{{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ALL_TOPICS') }}</span>
      </button>

      <button
        v-for="cluster in clusters"
        :key="cluster.key"
        type="button"
        class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium shadow-sm backdrop-blur-md transition-all"
        :class="
          activeClusterKey === cluster.key
            ? cluster.palette.chip
            : isDarkTheme
              ? 'border-white/10 bg-slate-900/75 text-slate-300 hover:text-white'
              : 'border-slate-200/90 bg-white/90 text-slate-700 hover:border-slate-300 hover:text-slate-950'
        "
        data-testid="knowledge-cluster-chip"
        @click="selectCluster(cluster.key)"
      >
        <span
          class="size-2 rounded-full"
          :style="{ backgroundColor: cluster.palette.dot }"
        />
        <span>{{ cluster.label }}</span>
      </button>
    </div>

    <!-- Top-Right Compact Floating 3D Controls -->
    <div
      class="pointer-events-auto absolute right-4 top-4 z-10 flex items-center gap-1 rounded-full border p-1 shadow-sm backdrop-blur-md"
      :class="
        isDarkTheme
          ? 'border-white/10 bg-slate-900/80 text-slate-200'
          : 'border-slate-200/90 bg-white/90 text-slate-700'
      "
    >
      <button
        type="button"
        class="inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium transition-all"
        :class="
          autoOrbit
            ? 'bg-sky-500/20 text-sky-600 dark:text-sky-300'
            : 'opacity-70 hover:opacity-100'
        "
        :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.AUTO_ORBIT')"
        @click="autoOrbit = !autoOrbit"
      >
        <Icon icon="i-lucide-rotate-3d" class="size-3.5" />
        <span class="hidden sm:inline">{{
          t('CAPTAIN.RESPONSES.GRAPH.AUTO_ORBIT')
        }}</span>
      </button>

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

    <!-- Floating Inspector Card (Only visible when a node is selected, dismissible via × or background click) -->
    <div
      v-if="selectedNode && inspectorOpen"
      class="pointer-events-auto absolute bottom-4 right-4 z-20 flex max-h-[calc(100%-5rem)] w-80 flex-col gap-3 overflow-y-auto rounded-2xl border p-4 shadow-2xl backdrop-blur-xl sm:w-96"
      :class="
        isDarkTheme
          ? 'border-white/10 bg-slate-900/90 text-slate-100'
          : 'border-slate-200/90 bg-white/95 text-slate-900'
      "
    >
      <div class="flex items-center justify-between gap-2">
        <span
          class="inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium"
          :class="selectedNode.palette.chip"
        >
          <span
            class="size-2 rounded-full"
            :style="{ backgroundColor: selectedNode.palette.dot }"
          />
          {{ selectedNode.clusterLabel }}
        </span>

        <div class="flex items-center gap-1">
          <button
            v-if="selectedNode.raw.documentable"
            type="button"
            class="inline-flex items-center gap-1 rounded-lg border border-n-weak bg-n-surface-1 px-2 py-0.5 text-[11px] text-n-slate-11"
            @click="handleSourceClick(selectedNode.raw.documentable)"
          >
            <Icon
              icon="i-lucide-file-text"
              class="size-3 shrink-0 text-n-brand"
            />
            <span
              v-if="
                selectedNode.raw.documentable.type === 'Captain::Document'
              "
              class="max-w-32 truncate"
            >
              {{ selectedNode.raw.documentable.name }}
            </span>
            <span v-else>
              {{
                t('CAPTAIN.RESPONSES.DOCUMENTABLE.CONVERSATION', {
                  id: selectedNode.raw.documentable.display_id,
                })
              }}
            </span>
          </button>

          <button
            type="button"
            class="inline-flex size-6 items-center justify-center rounded-lg text-n-slate-10 transition-colors hover:bg-n-alpha-2 hover:text-n-slate-12"
            @click="inspectorOpen = false"
          >
            <Icon icon="i-lucide-x" class="size-4" />
          </button>
        </div>
      </div>

      <h3 class="m-0 text-sm font-semibold leading-snug text-n-slate-12">
        {{ selectedNode.question }}
      </h3>

      <div
        class="flex flex-col gap-1.5 rounded-xl border border-n-weak bg-n-surface-1 p-3"
      >
        <div class="flex items-center justify-between gap-2">
          <span
            class="text-[11px] font-medium uppercase tracking-wide text-n-slate-10"
          >
            {{ t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ANSWER_LABEL') }}
          </span>
          <button
            type="button"
            class="inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[11px] text-n-slate-11 transition-colors hover:bg-n-alpha-2 hover:text-n-slate-12"
            @click="copyAnswerToClipboard"
          >
            <Icon
              :icon="copiedAnswer ? 'i-lucide-check' : 'i-lucide-copy'"
              class="size-3"
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
          class="m-0 whitespace-pre-line text-xs leading-relaxed text-n-slate-12"
        >
          {{ selectedNode.answer }}
        </p>
      </div>

      <div v-if="semanticPeers.length" class="flex flex-wrap gap-1.5">
        <button
          v-for="peer in semanticPeers"
          :key="peer.id"
          type="button"
          class="inline-flex items-center gap-1.5 rounded-lg border border-n-weak bg-n-surface-1 px-2 py-1 text-left text-[11px] text-n-slate-11 transition-colors hover:border-n-brand hover:text-n-slate-12"
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
  </div>
</template>
