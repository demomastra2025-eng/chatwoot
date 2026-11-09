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
  doctors: {
    type: Array,
    default: () => [],
  },
  services: {
    type: Array,
    default: () => [],
  },
  serviceStats: {
    type: Array,
    default: () => [],
  },
  searchQuery: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['navigate']);
const { t } = useI18n();

const VIEWPORT_WIDTH = 1080;
const VIEWPORT_HEIGHT = 640;
const CENTER_X = VIEWPORT_WIDTH / 2;
const CENTER_Y = VIEWPORT_HEIGHT / 2;

const DOCTOR_PALETTE = {
  stroke: '#2563eb',
  fill: 'rgba(37, 99, 235, 0.22)',
  chip: 'bg-n-blue-3/70 text-n-blue-11 border-n-blue-6',
  dot: '#3b82f6',
  emissive: '#1d4ed8',
};

const SERVICE_PALETTE = {
  stroke: '#059669',
  fill: 'rgba(16, 185, 129, 0.22)',
  chip: 'bg-n-teal-3/70 text-n-teal-11 border-n-teal-6',
  dot: '#10b981',
  emissive: '#047857',
};

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
      'онлайн',
    ],
    palette: {
      stroke: '#8b5cf6',
      fill: 'rgba(139, 92, 246, 0.22)',
      chip: 'bg-n-violet-3/70 text-n-violet-11 border-n-violet-6',
      dot: '#8b5cf6',
      emissive: '#7c3aed',
    },
  },
  {
    key: 'diagnostics',
    i18nKey: 'DIAGNOSTICS',
    icon: 'i-lucide-microscope',
    keywords: [
      'анализ',
      'узи',
      'мрт',
      'кт',
      'рентген',
      'экг',
      'кров',
      'лаборатор',
      'диагност',
      'обслед',
      'подготов',
      'натощак',
      'биопс',
      'эндоскоп',
      'фгдс',
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
      'филиал',
      'проезд',
      'парковк',
      'где наход',
      'локац',
      'карт',
      '2гис',
      '2gis',
      'этаж',
      'кабинет',
      'контакт',
      'телефон',
      'номер',
    ],
    palette: {
      stroke: '#ec4899',
      fill: 'rgba(236, 72, 153, 0.22)',
      chip: 'bg-n-ruby-3/70 text-n-ruby-11 border-n-ruby-6',
      dot: '#ec4899',
      emissive: '#db2777',
    },
  },
  {
    key: 'documents',
    i18nKey: 'DOCUMENTS',
    icon: 'i-lucide-file-Spreadsheet',
    keywords: [
      'справк',
      'больничн',
      'договор',
      'страхов',
      'осмс',
      'гобмп',
      'документ',
      'налог',
      'вычет',
      'рецепт',
      'выписк',
      'паспорт',
      'удостоверен',
    ],
    palette: {
      stroke: '#06b6d4',
      fill: 'rgba(6, 182, 212, 0.22)',
      chip: 'bg-n-iris-3/70 text-n-iris-11 border-n-iris-6',
      dot: '#06b6d4',
      emissive: '#0891b2',
    },
  },
];

const DEFAULT_CLUSTER = {
  key: 'general',
  i18nKey: 'GENERAL',
  icon: 'i-lucide-sparkles',
  palette: {
    stroke: '#64748b',
    fill: 'rgba(100, 116, 139, 0.22)',
    chip: 'bg-n-slate-3 text-n-slate-11 border-n-slate-6',
    dot: '#94a3b8',
    emissive: '#475569',
  },
};

const STOP_WORDS = new Set([
  'или',
  'как',
  'что',
  'для',
  'при',
  'это',
  'все',
  'она',
  'они',
  'его',
  'мне',
  'вам',
  'вас',
  'мы',
  'вы',
  'если',
  'есть',
  'можно',
  'нужно',
  'надо',
  'когда',
  'где',
  'кто',
  'чем',
  'без',
  'под',
  'над',
  'про',
  'только',
  'также',
  'еще',
  'ещё',
  'уже',
  'быть',
  'был',
  'были',
  'будет',
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

const formatPriceKzt = price => {
  const num = Number(price);
  if (!Number.isFinite(num) || num <= 0) return '';
  return `${num.toLocaleString('ru-RU')} ₸`;
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

const normalizedQuery = computed(() =>
  String(props.searchQuery || '')
    .trim()
    .toLowerCase()
);

const normalizedFaqs = computed(() =>
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
      kind: 'faq',
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

// Build unified Doctor <-> Service relational index from serviceStats + service.prices
const clinicRelations = computed(() => {
  const doctorMap = new Map();
  const serviceMap = new Map();
  const pairMap = new Map();

  (props.doctors || []).forEach(doc => {
    if (!doc || doc.active === false) return;
    const id = Number(doc.id);
    if (!id) return;
    const name = String(doc.name || '').trim();
    if (!name) return;
    const specialty = String(doc.specialty || '').trim();
    doctorMap.set(id, {
      id,
      nodeId: `doctor-${id}`,
      rawId: `doctor-${id}`,
      kind: 'doctor',
      name,
      specialty,
      description: String(doc.description || '').trim(),
      slotDurationMin: doc.slot_duration_min || 30,
      photoUrl: doc.photo_url || '',
      raw: doc,
      linkedServices: [],
      tokens: extractTokens(`${name} ${specialty} ${doc.description || ''}`),
    });
  });

  (props.services || []).forEach(srv => {
    if (!srv || srv.active === false) return;
    const id = Number(srv.id);
    if (!id) return;
    const name = String(srv.name || '').trim();
    if (!name) return;
    const category = String(srv.category || srv.direction || '').trim();
    serviceMap.set(id, {
      id,
      nodeId: `service-${id}`,
      rawId: `service-${id}`,
      kind: 'service',
      name,
      category,
      basePrice: Number(srv.base_price) || 0,
      durationMin: Number(srv.duration_min) || 30,
      description: String(srv.description || '').trim(),
      raw: srv,
      linkedDoctors: [],
      tokens: extractTokens(`${name} ${category} ${srv.description || ''}`),
    });

    if (Array.isArray(srv.prices)) {
      srv.prices.forEach(p => {
        if (p && p.active !== false && p.resource_id) {
          const docId = Number(p.resource_id);
          if (doctorMap.has(docId)) {
            const key = `${docId}:${id}`;
            const existing = pairMap.get(key) || {
              resourceId: docId,
              serviceId: id,
              receptionsCount: 0,
              medianDurationMin: null,
              price: null,
            };
            existing.price = Number(p.price) || srv.base_price || 0;
            pairMap.set(key, existing);
          }
        }
      });
    }
  });

  (props.serviceStats || []).forEach(st => {
    if (!st) return;
    if (st.status && !['auto', 'confirmed'].includes(st.status)) return;
    const docId = Number(st.resource_id ?? st.resourceId);
    const srvId = Number(st.service_id ?? st.serviceId);
    if (!doctorMap.has(docId) || !serviceMap.has(srvId)) return;
    const key = `${docId}:${srvId}`;
    const existing = pairMap.get(key) || {
      resourceId: docId,
      serviceId: srvId,
      receptionsCount: 0,
      medianDurationMin: null,
      price: null,
    };
    existing.receptionsCount =
      Number(st.receptions_count ?? st.receptionsCount) || 0;
    existing.medianDurationMin =
      st.median_duration_min ?? st.medianDurationMin ?? null;
    pairMap.set(key, existing);
  });

  pairMap.forEach(rel => {
    const doc = doctorMap.get(rel.resourceId);
    const srv = serviceMap.get(rel.serviceId);
    if (!doc || !srv) return;
    const effectivePrice = rel.price || srv.basePrice || 0;
    doc.linkedServices.push({
      serviceId: srv.id,
      nodeId: srv.nodeId,
      rawId: srv.rawId,
      name: srv.name,
      category: srv.category,
      receptionsCount: rel.receptionsCount,
      medianDurationMin: rel.medianDurationMin || srv.durationMin,
      price: effectivePrice,
    });
    srv.linkedDoctors.push({
      resourceId: doc.id,
      nodeId: doc.nodeId,
      rawId: doc.rawId,
      name: doc.name,
      specialty: doc.specialty,
      receptionsCount: rel.receptionsCount,
      medianDurationMin: rel.medianDurationMin || srv.durationMin,
      price: effectivePrice,
    });
  });

  doctorMap.forEach(doc => {
    doc.linkedServices.sort(
      (a, b) => (b.receptionsCount || 0) - (a.receptionsCount || 0)
    );
  });
  serviceMap.forEach(srv => {
    srv.linkedDoctors.sort(
      (a, b) => (b.receptionsCount || 0) - (a.receptionsCount || 0)
    );
  });

  return {
    doctors: Array.from(doctorMap.values()),
    services: Array.from(serviceMap.values()),
    pairs: Array.from(pairMap.values()),
  };
});

const clusters = computed(() => {
  const map = new Map();
  normalizedFaqs.value.forEach(node => {
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

const hasClinicEntities = computed(
  () =>
    clinicRelations.value.doctors.length > 0 ||
    clinicRelations.value.services.length > 0
);

const buildGraphTopology = () => {
  const q = normalizedQuery.value;
  const filterKey = activeClusterKey.value;

  const includeDoctors =
    filterKey === 'all' ||
    filterKey === 'clinic' ||
    filterKey === 'only_doctors' ||
    filterKey === 'doctors';
  const includeServices =
    filterKey === 'all' ||
    filterKey === 'clinic' ||
    filterKey === 'only_services' ||
    filterKey === 'pricing';
  const includeFaqs =
    filterKey !== 'clinic' &&
    filterKey !== 'only_doctors' &&
    filterKey !== 'only_services';

  const filteredFaqs = includeFaqs
    ? normalizedFaqs.value.filter(item => {
        if (filterKey !== 'all' && item.clusterKey !== filterKey) return false;
        if (!q) return true;
        return (
          item.question.toLowerCase().includes(q) ||
          item.answer.toLowerCase().includes(q)
        );
      })
    : [];

  const filteredDoctors = includeDoctors
    ? clinicRelations.value.doctors.filter(doc => {
        if (!q) return true;
        return (
          doc.name.toLowerCase().includes(q) ||
          doc.specialty.toLowerCase().includes(q) ||
          doc.linkedServices.some(s => s.name.toLowerCase().includes(q))
        );
      })
    : [];

  const visibleDoctorIds = new Set(filteredDoctors.map(d => d.id));

  // Include all services linked to visible doctors + top services matching query (capped for 60fps 3D rendering)
  let candidateServices = [];
  if (includeServices) {
    const allSrv = clinicRelations.value.services.filter(srv => {
      if (!q) return true;
      return (
        srv.name.toLowerCase().includes(q) ||
        srv.category.toLowerCase().includes(q) ||
        srv.linkedDoctors.some(d => d.name.toLowerCase().includes(q))
      );
    });
    const linked = allSrv.filter(srv =>
      srv.linkedDoctors.some(d => visibleDoctorIds.has(d.resourceId))
    );
    const unlinked = allSrv.filter(
      srv => !srv.linkedDoctors.some(d => visibleDoctorIds.has(d.resourceId))
    );
    const maxServices = filterKey === 'only_services' ? 140 : 100;
    candidateServices = [
      ...linked.slice(0, maxServices),
      ...unlinked.slice(0, Math.max(0, 45 - linked.length)),
    ];
  }

  const visibleServiceIds = new Set(candidateServices.map(s => s.id));

  if (
    !filteredFaqs.length &&
    !filteredDoctors.length &&
    !candidateServices.length
  ) {
    simNodes.value = [];
    simEdges.value = [];
    return { nodes: [], links: [] };
  }

  const nodes = [];
  const links = [];

  // Central AI Hub
  nodes.push({
    id: 'core-hub',
    kind: 'core',
    label: t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.CENTER_HUB'),
    radius: 26,
    val: 36,
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
    degree: 1,
  });

  // 1. Doctors Wing & Doctor Nodes
  if (filteredDoctors.length > 0) {
    const doctorsHubId = 'hub-clinic-doctors';
    nodes.push({
      id: doctorsHubId,
      kind: 'cluster',
      clusterKey: 'only_doctors',
      label: `Врачи (${filteredDoctors.length})`,
      shortLabel: 'Врачи',
      count: filteredDoctors.length,
      radius: 20,
      val: 24,
      x: CENTER_X - 180,
      y: CENTER_Y - 70,
      z: 50,
      palette: DOCTOR_PALETTE,
      degree: filteredDoctors.length,
    });

    links.push({
      id: 'link-core-doctors-hub',
      source: 'core-hub',
      target: doctorsHubId,
      kind: 'backbone',
      stroke: DOCTOR_PALETTE.stroke,
      distance: 140,
      strength: 0.85,
    });

    filteredDoctors.forEach((doc, idx) => {
      const angle = (idx / Math.max(filteredDoctors.length, 1)) * Math.PI * 2;
      const dist = 95 + (idx % 4) * 28;
      const shortLabel = doc.specialty
        ? `${truncateText(doc.name, 22)} • ${truncateText(doc.specialty, 16)}`
        : truncateText(doc.name, 28);

      nodes.push({
        id: doc.nodeId,
        rawId: doc.rawId,
        kind: 'doctor',
        label: shortLabel,
        question: doc.name,
        answer:
          doc.description ||
          (doc.specialty
            ? `Специализация: ${doc.specialty}. Длительность приёма: ${doc.slotDurationMin} мин.`
            : `Длительность приёма: ${doc.slotDurationMin} мин.`),
        specialty: doc.specialty,
        slotDurationMin: doc.slotDurationMin,
        linkedServices: doc.linkedServices,
        clusterKey: 'only_doctors',
        clusterLabel: doc.specialty || 'Врач клиники',
        raw: doc.raw,
        palette: DOCTOR_PALETTE,
        radius: Math.min(15, 9.5 + Math.sqrt(doc.linkedServices.length) * 1.4),
        val: 10 + Math.min(18, doc.linkedServices.length * 1.8),
        degree: 1 + doc.linkedServices.length,
        x: CENTER_X - 180 + Math.cos(angle) * dist,
        y: CENTER_Y - 70 + Math.sin(angle) * dist,
        z: 50 + ((idx % 5) - 2) * 35,
      });

      links.push({
        id: `link-hub-doc-${doc.id}`,
        source: doctorsHubId,
        target: doc.nodeId,
        kind: 'topic',
        stroke: DOCTOR_PALETTE.stroke,
        distance: 90,
        strength: 0.65,
      });
    });
  }

  // 2. Services Wing & Service Nodes + Direct Doctor <-> Service Links
  if (candidateServices.length > 0) {
    const servicesHubId = 'hub-clinic-services';
    nodes.push({
      id: servicesHubId,
      kind: 'cluster',
      clusterKey: 'only_services',
      label: `Услуги (${clinicRelations.value.services.length})`,
      shortLabel: 'Услуги',
      count: clinicRelations.value.services.length,
      radius: 20,
      val: 24,
      x: CENTER_X + 180,
      y: CENTER_Y - 70,
      z: -50,
      palette: SERVICE_PALETTE,
      degree: candidateServices.length,
    });

    links.push({
      id: 'link-core-services-hub',
      source: 'core-hub',
      target: servicesHubId,
      kind: 'backbone',
      stroke: SERVICE_PALETTE.stroke,
      distance: 145,
      strength: 0.85,
    });

    candidateServices.forEach((srv, idx) => {
      const angle = (idx / Math.max(candidateServices.length, 1)) * Math.PI * 2;
      const dist = 105 + (idx % 5) * 26;
      const priceText = formatPriceKzt(srv.basePrice);
      const shortLabel = priceText
        ? `${truncateText(srv.name, 24)} (${priceText})`
        : truncateText(srv.name, 28);

      const connectedDocs = srv.linkedDoctors.filter(d =>
        visibleDoctorIds.has(d.resourceId)
      );

      nodes.push({
        id: srv.nodeId,
        rawId: srv.rawId,
        kind: 'service',
        label: shortLabel,
        question: srv.name,
        answer: [
          srv.category ? `Категория: ${srv.category}` : '',
          priceText ? `Базовая стоимость: ${priceText}` : '',
          srv.durationMin ? `Длительность: ${srv.durationMin} мин.` : '',
          srv.description || '',
        ]
          .filter(Boolean)
          .join('\n'),
        category: srv.category,
        basePrice: srv.basePrice,
        durationMin: srv.durationMin,
        linkedDoctors: srv.linkedDoctors,
        clusterKey: 'only_services',
        clusterLabel: srv.category || 'Услуга клиники',
        raw: srv.raw,
        palette: SERVICE_PALETTE,
        radius: Math.min(14, 7.5 + connectedDocs.length * 1.5),
        val: 6.5 + Math.min(14, connectedDocs.length * 2.2),
        degree: 1 + connectedDocs.length,
        x: CENTER_X + 180 + Math.cos(angle) * dist,
        y: CENTER_Y - 70 + Math.sin(angle) * dist,
        z: -50 + ((idx % 5) - 2) * 35,
      });

      // Connect every Doctor who performs this Service directly to this Service node!
      if (connectedDocs.length > 0) {
        connectedDocs.forEach(docLink => {
          links.push({
            id: `link-doc-srv-${docLink.resourceId}-${srv.id}`,
            source: `doctor-${docLink.resourceId}`,
            target: srv.nodeId,
            kind: 'doctor_service',
            receptionsCount: docLink.receptionsCount,
            stroke: '#10b981',
            distance: 95,
            strength: 0.75,
          });
        });
      }

      // Also keep a gentle tether to Services Hub so services stay organized
      links.push({
        id: `link-hub-srv-${srv.id}`,
        source: servicesHubId,
        target: srv.nodeId,
        kind: 'topic',
        stroke: SERVICE_PALETTE.stroke,
        distance: connectedDocs.length > 0 ? 145 : 95,
        strength: connectedDocs.length > 0 ? 0.25 : 0.65,
      });
    });
  }

  // 3. FAQ Clusters & FAQ Nodes + Cross-Links to Doctors & Services
  if (filteredFaqs.length > 0) {
    const activeFaqClusters = clusters.value.filter(c =>
      filteredFaqs.some(f => f.clusterKey === c.key)
    );
    const clusterAnchors = new Map();

    activeFaqClusters.forEach((cluster, idx) => {
      const angle =
        (idx / Math.max(activeFaqClusters.length, 1)) * Math.PI * 2 +
        Math.PI / 4;
      const orbit = 165;
      const cx = CENTER_X + Math.cos(angle) * orbit;
      const cy = CENTER_Y + 80 + Math.sin(angle) * orbit;
      const cz = ((idx % 3) - 1) * 55;
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
        radius: Math.min(20, 14 + Math.sqrt(cluster.count) * 2),
        val: 16 + cluster.count * 1.4,
        x: cx,
        y: cy,
        z: cz,
        palette: cluster.palette,
        degree: cluster.count,
      });

      links.push({
        id: `link-core-${cluster.key}`,
        source: 'core-hub',
        target: clusterNodeId,
        kind: 'backbone',
        stroke: cluster.palette.stroke,
        distance: 140,
        strength: 0.8,
      });
    });

    filteredFaqs.forEach((item, idx) => {
      const anchor = clusterAnchors.get(item.clusterKey) || {
        x: CENTER_X,
        y: CENTER_Y,
        z: 0,
        angle: 0,
        id: 'core-hub',
      };
      const spreadAngle =
        anchor.angle + ((idx % 9) - 4) * 0.25 + (idx * 0.61803398875) % 0.5;
      const dist = 78 + (idx % 4) * 26;

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

      // Cross-link FAQ to matching Doctor or Service if tokens overlap
      filteredDoctors.forEach(doc => {
        if (computeJaccard(item.tokens, doc.tokens) >= 0.14) {
          links.push({
            id: `sem-faq-doc-${item.id}-${doc.id}`,
            source: item.id,
            target: doc.nodeId,
            kind: 'semantic',
            stroke: DOCTOR_PALETTE.stroke,
            distance: 95,
            strength: 0.35,
          });
        }
      });

      candidateServices.forEach(srv => {
        if (
          visibleServiceIds.has(srv.id) &&
          computeJaccard(item.tokens, srv.tokens) >= 0.18
        ) {
          links.push({
            id: `sem-faq-srv-${item.id}-${srv.id}`,
            source: item.id,
            target: srv.nodeId,
            kind: 'semantic',
            stroke: SERVICE_PALETTE.stroke,
            distance: 95,
            strength: 0.35,
          });
        }
      });
    });

    // Semantic links between FAQ items
    for (let i = 0; i < filteredFaqs.length; i += 1) {
      let bestPeer = null;
      let bestScore = 0;
      for (let j = i + 1; j < filteredFaqs.length; j += 1) {
        const score = computeJaccard(
          filteredFaqs[i].tokens,
          filteredFaqs[j].tokens
        );
        if (score > bestScore && score >= 0.16) {
          bestScore = score;
          bestPeer = filteredFaqs[j];
        }
      }
      if (bestPeer) {
        links.push({
          id: `sem-${filteredFaqs[i].id}-${bestPeer.id}`,
          source: filteredFaqs[i].id,
          target: bestPeer.id,
          kind: 'semantic',
          similarity: bestScore,
          stroke: filteredFaqs[i].palette.stroke,
          distance: 95,
          strength: 0.25,
        });
      }
    }
  }

  // Settled 2D layout for instant fallback & deterministic unit tests
  const sim2dNodes = nodes.map(n => ({ ...n, fx: undefined, fy: undefined }));
  const sim2dLinks = links.map(l => ({ ...l }));
  const sim = forceSimulation(sim2dNodes)
    .force(
      'link',
      forceLink(sim2dLinks)
        .id(d => d.id)
        .distance(d => d.distance || 90)
    )
    .force('charge', forceManyBody().strength(-160))
    .force('collide', forceCollide().radius(d => (d.radius || 8) + 12))
    .force('center', forceCenter(CENTER_X, CENTER_Y))
    .stop();
  sim.tick(65);

  simNodes.value = sim2dNodes;
  simEdges.value = sim2dLinks.map(l => ({
    id: l.id,
    kind: l.kind,
    stroke: l.stroke,
    sourceId: typeof l.source === 'object' ? l.source.id : l.source,
    targetId: typeof l.target === 'object' ? l.target.id : l.target,
  }));

  const nodes3d = nodes.map(n => ({
    ...n,
    x: ((n.x || CENTER_X) - CENTER_X) * 0.75,
    y: ((n.y || CENTER_Y) - CENTER_Y) * 0.75,
    z: n.z || 0,
  }));
  const links3d = links.map(l => ({
    ...l,
    source: typeof l.source === 'object' ? l.source.id : l.source,
    target: typeof l.target === 'object' ? l.target.id : l.target,
  }));

  return { nodes: nodes3d, links: links3d };
};

const selectableNodes = computed(() =>
  simNodes.value.filter(n => ['faq', 'doctor', 'service'].includes(n.kind))
);

const faqNodes = computed(() =>
  simNodes.value.filter(n => ['faq', 'doctor', 'service'].includes(n.kind))
);

const selectedNode = computed(() => {
  if (!selectableNodes.value.length) return null;
  return (
    selectableNodes.value.find(node => node.rawId === selectedNodeId.value) ||
    selectableNodes.value[0]
  );
});

const buildNodeThreeObject = node => {
  const group = new THREE.Group();
  const dark = isDarkTheme.value;
  const isSelected =
    ['faq', 'doctor', 'service'].includes(node.kind) &&
    inspectorOpen.value &&
    selectedNode.value?.rawId === node.rawId;

  const baseRadius =
    node.kind === 'core'
      ? 14
      : node.kind === 'cluster'
        ? 9.5
        : node.kind === 'doctor'
          ? isSelected
            ? 8.2
            : 6.6
          : isSelected
            ? 6.4
            : 4.6;

  const sphereGeo = new THREE.SphereGeometry(baseRadius, 28, 28);
  const sphereMat = new THREE.MeshStandardMaterial({
    color: new THREE.Color(
      isSelected && dark ? '#ffffff' : node.palette.dot
    ),
    emissive: new THREE.Color(node.palette.dot),
    emissiveIntensity: dark
      ? node.kind === 'core'
        ? 1.35
        : node.kind === 'cluster' || node.kind === 'doctor'
          ? 1.05
          : isSelected
            ? 1.45
            : 0.72
      : isSelected
        ? 0.42
        : 0.22,
    roughness: dark ? 0.18 : 0.22,
    metalness: dark ? 0.35 : 0.12,
  });
  const sphereMesh = new THREE.Mesh(sphereGeo, sphereMat);
  group.add(sphereMesh);

  // Outer translucent energy halo for core, clusters, doctors, and selected node
  if (
    node.kind === 'core' ||
    node.kind === 'cluster' ||
    node.kind === 'doctor' ||
    isSelected
  ) {
    const haloGeo = new THREE.SphereGeometry(baseRadius * 1.52, 24, 24);
    const haloMat = new THREE.MeshBasicMaterial({
      color: new THREE.Color(node.palette.dot),
      transparent: true,
      opacity: dark ? (isSelected ? 0.3 : 0.16) : isSelected ? 0.22 : 0.12,
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
  const isProminent =
    node.kind === 'core' ||
    node.kind === 'cluster' ||
    node.kind === 'doctor' ||
    isSelected;
  if (dark) {
    sprite.color = isProminent ? '#f8fafc' : '#cbd5e1';
    sprite.backgroundColor = isProminent
      ? 'rgba(15, 23, 42, 0.86)'
      : 'rgba(15, 23, 42, 0.54)';
  } else {
    sprite.color = isProminent ? '#0f172a' : '#334155';
    sprite.backgroundColor = isProminent
      ? 'rgba(255, 255, 255, 0.94)'
      : 'rgba(248, 250, 252, 0.86)';
  }
  sprite.textHeight =
    node.kind === 'core'
      ? 5.2
      : node.kind === 'cluster'
        ? 4.2
        : node.kind === 'doctor'
          ? 3.7
          : isSelected
            ? 3.6
            : 2.85;
  sprite.fontWeight = isProminent ? '700' : '500';
  sprite.fontFace = 'Inter, system-ui, -apple-system, sans-serif';
  sprite.padding = isProminent ? 2.2 : 1.4;
  sprite.borderRadius = 4;
  if (isProminent || !dark) {
    sprite.borderWidth = isProminent ? 0.55 : 0.3;
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
  const distance = 140;
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
  fg.cameraPosition({ x: 0, y: 36, z: 380 }, { x: 0, y: 0, z: 0 }, 900);
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
    fg.linkOpacity(dark ? 0.44 : 0.58);
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
      orbitAngleRef.value += 0.0018;
      const radius = 380;
      fg.cameraPosition({
        x: radius * Math.sin(orbitAngleRef.value),
        y: 30 * Math.sin(orbitAngleRef.value * 0.6),
        z: radius * Math.cos(orbitAngleRef.value),
      });
    }
    orbitRafRef.value = requestAnimationFrame(step);
  };
  orbitRafRef.value = requestAnimationFrame(step);
};

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
      .linkOpacity(dark ? 0.44 : 0.58)
      .linkWidth(link => {
        if (link.kind === 'backbone') return 2.0;
        if (link.kind === 'doctor_service') return 1.75;
        if (link.kind === 'semantic') return 0.95;
        return 1.25;
      })
      .linkCurvature(link => {
        if (link.kind === 'doctor_service') return 0.22;
        if (link.kind === 'semantic') return 0.28;
        return 0.1;
      })
      .linkDirectionalParticles(link => {
        if (link.kind === 'backbone') return 3;
        if (link.kind === 'doctor_service') return 2;
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
        if (['faq', 'doctor', 'service'].includes(node.kind)) {
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
      linkForce.distance(link => link.distance || 90);
    }
    const chargeForce = fg.d3Force('charge');
    if (chargeForce) {
      chargeForce.strength(node => {
        if (node.kind === 'core') return -440;
        if (node.kind === 'cluster') return -260;
        if (node.kind === 'doctor') return -180;
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
    fg.cameraPosition({ x: 0, y: 36, z: 380 });

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
  [
    normalizedFaqs,
    clinicRelations,
    activeClusterKey,
    normalizedQuery,
  ],
  () => {
    const topology = buildGraphTopology();
    const list = simNodes.value.filter(n =>
      ['faq', 'doctor', 'service'].includes(n.kind)
    );
    if (
      !list.some(n => n.rawId === selectedNodeId.value) &&
      list.length > 0
    ) {
      selectedNodeId.value = list[0].rawId;
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
  if (
    typeof MutationObserver !== 'undefined' &&
    typeof document !== 'undefined'
  ) {
    const mo = new MutationObserver(() => {
      const nextDark = detectDarkMode();
      if (nextDark !== isDarkTheme.value) {
        isDarkTheme.value = nextDark;
      }
    });
    if (document.body) {
      mo.observe(document.body, {
        attributes: true,
        attributeFilter: ['class'],
      });
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

const semanticPeers = computed(() => {
  if (!selectedNode.value) return [];
  const targetId = selectedNode.value.id;
  const peerIds = new Set();
  simEdges.value.forEach(edge => {
    if (edge.kind === 'semantic' || edge.kind === 'doctor_service') {
      if (edge.sourceId === targetId) peerIds.add(edge.targetId);
      if (edge.targetId === targetId) peerIds.add(edge.sourceId);
    }
  });
  return selectableNodes.value.filter(n => peerIds.has(n.id)).slice(0, 8);
});

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

    <!-- Top-Left Floating Topic & Clinic Filter Pills -->
    <div
      v-if="hasClinicEntities || clusters.length > 1"
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
        v-if="
          clinicRelations.doctors.length > 0 &&
          clinicRelations.services.length > 0
        "
        type="button"
        class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium shadow-sm backdrop-blur-md transition-all"
        :class="
          activeClusterKey === 'clinic'
            ? 'border-blue-500 bg-blue-600 text-white'
            : isDarkTheme
              ? 'border-white/10 bg-slate-900/75 text-slate-300 hover:text-white'
              : 'border-slate-200/90 bg-white/90 text-slate-700 hover:border-slate-300 hover:text-slate-950'
        "
        data-testid="knowledge-clinic-links-chip"
        @click="selectCluster('clinic')"
      >
        <Icon icon="i-lucide-git-Fork" class="size-3.5 text-sky-400" />
        <span>Врачи ↔ Услуги ({{ clinicRelations.pairs.length }})</span>
      </button>

      <button
        v-if="clinicRelations.doctors.length > 0"
        type="button"
        class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium shadow-sm backdrop-blur-md transition-all"
        :class="
          activeClusterKey === 'only_doctors'
            ? DOCTOR_PALETTE.chip
            : isDarkTheme
              ? 'border-white/10 bg-slate-900/75 text-slate-300 hover:text-white'
              : 'border-slate-200/90 bg-white/90 text-slate-700 hover:border-slate-300 hover:text-slate-950'
        "
        @click="selectCluster('only_doctors')"
      >
        <span
          class="size-2 rounded-full"
          :style="{ backgroundColor: DOCTOR_PALETTE.dot }"
        />
        <span>Врачи ({{ clinicRelations.doctors.length }})</span>
      </button>

      <button
        v-if="clinicRelations.services.length > 0"
        type="button"
        class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium shadow-sm backdrop-blur-md transition-all"
        :class="
          activeClusterKey === 'only_services'
            ? SERVICE_PALETTE.chip
            : isDarkTheme
              ? 'border-white/10 bg-slate-900/75 text-slate-300 hover:text-white'
              : 'border-slate-200/90 bg-white/90 text-slate-700 hover:border-slate-300 hover:text-slate-950'
        "
        @click="selectCluster('only_services')"
      >
        <span
          class="size-2 rounded-full"
          :style="{ backgroundColor: SERVICE_PALETTE.dot }"
        />
        <span>Услуги ({{ clinicRelations.services.length }})</span>
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

    <!-- Floating Inspector Card (Supports Doctor, Service, and FAQ nodes) -->
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
            v-if="selectedNode.raw?.documentable"
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

      <!-- Doctor Node: Linked Services List -->
      <div
        v-if="
          selectedNode.kind === 'doctor' &&
          selectedNode.linkedServices?.length
        "
        class="flex flex-col gap-1.5"
      >
        <span
          class="text-[11px] font-medium uppercase tracking-wide text-n-slate-10"
        >
          Связанные услуги ({{ selectedNode.linkedServices.length }})
        </span>
        <div class="flex max-h-56 flex-col gap-1 overflow-y-auto pr-1">
          <button
            v-for="srv in selectedNode.linkedServices"
            :key="srv.serviceId"
            type="button"
            class="flex items-center justify-between gap-2 rounded-xl border border-n-weak bg-n-surface-1 px-2.5 py-1.5 text-left text-xs transition-colors hover:border-n-brand"
            @click="selectNode(srv.rawId)"
          >
            <span class="truncate font-medium text-n-slate-12">
              {{ srv.name }}
            </span>
            <span class="shrink-0 text-[11px] text-n-slate-10">
              <template v-if="srv.price">
                {{ formatPriceKzt(srv.price) }}
              </template>
              <template v-else-if="srv.receptionsCount">
                {{ srv.receptionsCount }} пр.
              </template>
            </span>
          </button>
        </div>
      </div>

      <!-- Service Node: Linked Doctors List -->
      <div
        v-if="
          selectedNode.kind === 'service' &&
          selectedNode.linkedDoctors?.length
        "
        class="flex flex-col gap-1.5"
      >
        <span
          class="text-[11px] font-medium uppercase tracking-wide text-n-slate-10"
        >
          Выполняют врачи ({{ selectedNode.linkedDoctors.length }})
        </span>
        <div class="flex flex-wrap gap-1.5">
          <button
            v-for="doc in selectedNode.linkedDoctors"
            :key="doc.resourceId"
            type="button"
            class="inline-flex items-center gap-1.5 rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-1 text-left text-xs text-n-slate-12 transition-colors hover:border-n-brand"
            @click="selectNode(doc.rawId)"
          >
            <span
              class="size-1.5 rounded-full"
              :style="{ backgroundColor: DOCTOR_PALETTE.dot }"
            />
            <span>{{ doc.name }}</span>
          </button>
        </div>
      </div>

      <!-- Details / Answer Box -->
      <div
        v-if="selectedNode.answer"
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
