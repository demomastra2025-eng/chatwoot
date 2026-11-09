<script setup>
/* eslint-disable no-nested-ternary, no-restricted-syntax, no-continue, no-use-before-define */
import {
  computed,
  ref,
  shallowRef,
  watch,
  onMounted,
  onBeforeUnmount,
} from 'vue';
import { useI18n } from 'vue-i18n';
import {
  forceSimulation,
  forceLink,
  forceManyBody,
  forceCollide,
  forceRadial,
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

const UI_LABELS = {
  clinicPairs: count => `Врачи ↔ Услуги (${count})`,
  doctorsChip: count => `Врачи (${count})`,
  servicesChip: count => `Услуги (${count})`,
  legendSkill: 'врач / навык (FAQ)',
  legendMemory: 'услуга клиники',
  legendSub: 'ядро = специалисты · орбита = услуги и база знаний',
  linkedServicesHeader: count => `Связанные услуги (${count})`,
  linkedDoctorsHeader: count => `Выполняют врачи (${count})`,
  receptionsCount: count => `x${count}`,
};

// ── Hermes Starmap Constants ─────────────────────────────────────────────────
const RING_INNER = 58;
const RING_OUTER = 340;
const ZOOM_MIN = 0.3;
const ZOOM_MAX = 5;
const FIT_PADDING = 80;
const TILT = 1;
const RING_STEPS = 4;
const LEAD_IN = 0.06;

const WHITE = { r: 255, g: 255, b: 255 };
const BLACK = { r: 0, g: 0, b: 0 };

const AGE_GRADIENT = {
  mid: 0.52,
  midInk: 0.74,
  newInk: 0.95,
  oldInk: 0.42,
  reach: 1,
};

const ORB_DARKEN = 0.3;
const WHITEISH_SHEEN = 0.95;
const LIT_BAND_ALPHA = 0.04;

const MODE_DEFAULTS = {
  dark: {
    lineAlpha: 0.24,
    lineDash: 1.5,
    lineDashed: true,
    lineWidth: 0.5,
    ringAlpha: 0.1,
    ringDash: 4,
    ringDashed: false,
    ringWidth: 1.5,
  },
  light: {
    lineAlpha: 0.18,
    lineDash: 1.5,
    lineDashed: true,
    lineWidth: 0.5,
    ringAlpha: 0.08,
    ringDash: 4,
    ringDashed: false,
    ringWidth: 1.5,
  },
};

const RING_PARAMS = {
  dark: { bandAlpha: 0.012, lightSize: 0.64, ringAlpha: 0.065, sheen: 0.12 },
  light: { bandAlpha: 0.03, lightSize: 0.27, ringAlpha: 0.045, sheen: 0.1 },
};

const SCRAMBLE_CHARS =
  'ﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾜﾝｦｱｳｴｵｶｷｹｺｻｼｽｾﾀﾁﾂﾃﾅﾆﾇﾈ0123456789:.=*+<>Ξ╳';
const SCRAMBLE_RADIUS = 6;
const SCRAMBLE_CELL_MIN = 5;
const SCRAMBLE_CELL_MAX = 13;

const SPRITE_R = 96;
const spriteCache = new Map();

// ── Geometry & Color Helpers ─────────────────────────────────────────────────
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

const hash = input => {
  let h = 2166136261;
  const s = String(input || '');
  for (let i = 0; i < s.length; i += 1) {
    // eslint-disable-next-line no-bitwise
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  // eslint-disable-next-line no-bitwise
  return h >>> 0;
};

const rgba = (c, a) => `rgba(${c.r},${c.g},${c.b},${a})`;

const mixRgb = (a, b, tVal) => {
  const p = clamp(tVal, 0, 1);
  return {
    r: Math.round(a.r + (b.r - a.r) * p),
    g: Math.round(a.g + (b.g - a.g) * p),
    b: Math.round(a.b + (b.b - a.b) * p),
  };
};

const darken = (c, amount) => mixRgb(c, BLACK, amount);

const luminance = (r, g, b) => (0.2126 * r + 0.7152 * g + 0.114 * b) / 255;

const rgbToHsl = c => {
  const r = c.r / 255;
  const g = c.g / 255;
  const b = c.b / 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  const d = max - min;
  let h = 0;
  let s = 0;
  if (d) {
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    h =
      (max === r
        ? (g - b) / d + (g < b ? 6 : 0)
        : max === g
          ? (b - r) / d + 2
          : (r - g) / d + 4) * 60;
  }
  return [h, s, l];
};

const hslToRgb = (h, s, l) => {
  const hue = ((h % 360) + 360) % 360;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((hue / 60) % 2) - 1));
  const m = l - c / 2;
  const [r, g, b] =
    hue < 60
      ? [c, x, 0]
      : hue < 120
        ? [x, c, 0]
        : hue < 180
          ? [0, c, x]
          : hue < 240
            ? [0, x, c]
            : hue < 300
              ? [x, 0, c]
              : [c, 0, x];
  return {
    r: Math.round((r + m) * 255),
    g: Math.round((g + m) * 255),
    b: Math.round((b + m) * 255),
  };
};

const complementaryInk = c => {
  const [h, s, l] = rgbToHsl(c);
  return hslToRgb(h + 165, Math.max(s, 0.5), clamp(l, 0.5, 0.7));
};

const memoryInkFor = (primary, bg) =>
  mixRgb(complementaryInk(primary), bg, 0.45);

const computePalette = darkTheme => {
  const base = darkTheme ? WHITE : { r: 15, g: 23, b: 42 };
  const bg = darkTheme ? { r: 10, g: 10, b: 12 } : { r: 255, g: 255, b: 255 };
  // Exact Hermes warm silver-sand primary in dark mode; crisp slate-bronze in light mode
  const primary = darkTheme
    ? { r: 196, g: 181, b: 166 }
    : { r: 100, g: 116, b: 139 };

  return {
    bandInk: mixRgb(primary, base, darkTheme ? 0.3 : 0),
    base,
    bg,
    c: MODE_DEFAULTS[darkTheme ? 'dark' : 'light'],
    chipBg: darkTheme ? 'rgba(0,0,0,0.76)' : 'rgba(255,255,255,0.9)',
    darkTheme,
    inkInv: darkTheme ? 'rgba(0,0,0,1)' : 'rgba(255,255,255,1)',
    memoryInk: memoryInkFor(primary, bg),
    primary,
    skillInk: mixRgb(primary, base, darkTheme ? 0.12 : 0.18),
  };
};

const recForRatio = ratio => LEAD_IN + (1 - LEAD_IN) * clamp(ratio, 0, 1);

const radiusForRecency = (rec, outer = RING_OUTER) =>
  RING_INNER + rec * (outer - RING_INNER);

const RING_CORE = radiusForRecency(recForRatio(0));
const RING_BAND = (radiusForRecency(recForRatio(1)) - RING_CORE) / RING_STEPS;
const ringRadius = i => RING_CORE + i * RING_BAND;

const placeRadius = (i, id) => {
  const outer = ringRadius(i);
  const inner = i > 0 ? ringRadius(i - 1) : RING_CORE - RING_BAND * 0.5;
  const h = (hash(id) % 1000) / 1000;
  return outer - (0.15 + 0.7 * h) * (outer - inner);
};

const nodeRadius = n => {
  if (n.starmapKind === 'memory') {
    return 4.4;
  }
  const base = 3.2;
  return clamp(
    base +
      Math.sqrt(Math.max(0, n.useCount || 0)) * 0.55 +
      (n.pinned ? 0.8 : 0),
    3.2,
    13.5
  );
};

const recencyInk = rec => {
  const reach = Math.max(0.01, AGE_GRADIENT.reach);
  const mid = clamp(AGE_GRADIENT.mid, 0.01, 0.99);
  const tVal = clamp(rec / reach, 0, 1);
  if (tVal <= mid) {
    const p = tVal / mid;
    return (
      AGE_GRADIENT.oldInk +
      (AGE_GRADIENT.midInk - AGE_GRADIENT.oldInk) * (p * p * (3 - 2 * p))
    );
  }
  const p = (tVal - mid) / (1 - mid);
  return (
    AGE_GRADIENT.midInk +
    (AGE_GRADIENT.newInk - AGE_GRADIENT.midInk) * (p * p * (3 - 2 * p))
  );
};

const shapePath = (ctx, shape, x, y, r) => {
  ctx.beginPath();
  if (shape === 'circle') {
    ctx.arc(x, y, r, 0, Math.PI * 2);
    return;
  }
  const pts = shape === 'diamond' ? 4 : 6;
  const rot = shape === 'hexagon' ? Math.PI / 6 : -Math.PI / 2;
  for (let i = 0; i < pts; i += 1) {
    const a = rot + (i / pts) * Math.PI * 2;
    const px = x + Math.cos(a) * r;
    const py = y + Math.sin(a) * r;
    if (i === 0) ctx.moveTo(px, py);
    else ctx.lineTo(px, py);
  }
  ctx.closePath();
};

const fitViewport = (w, h, outer = RING_OUTER) => {
  if (w <= 0 || h <= 0) {
    return { k: 1, x: w / 2, y: h / 2 };
  }
  const kFor = r => {
    const spanX = (r + 30) * 2;
    return Math.min(
      (w - FIT_PADDING * 2) / spanX,
      (h - FIT_PADDING * 2) / (spanX * TILT),
      2.2
    );
  };
  const k = clamp(Math.max(kFor(outer), kFor(RING_OUTER)), ZOOM_MIN, ZOOM_MAX);
  return { k, x: w / 2, y: h / 2 + h * 0.02 };
};

const fitScale = (w, h, rings) =>
  fitViewport(w, h, rings[rings.length - 1]?.r ?? RING_OUTER).k;

const sphereSprite = (ink, strength, bodyDarken) => {
  const key = `${ink.r},${ink.g},${ink.b}|${strength}|${bodyDarken}`;
  const cached = spriteCache.get(key);
  if (cached) return cached;

  const R = SPRITE_R;
  const pad = Math.ceil(R * 0.15) + 1;
  const size = (R + pad) * 2;
  const c = R + pad;
  const cv = document.createElement('canvas');
  cv.width = size;
  cv.height = size;
  const g2 = cv.getContext('2d');
  if (!g2) return cv;

  const mx = Math.max(ink.r, ink.g, ink.b);
  const mn = Math.min(ink.r, ink.g, ink.b);
  const sat = mx ? (mx - mn) / mx : 0;
  const whiteness =
    clamp((luminance(ink.r, ink.g, ink.b) - 0.7) / 0.3, 0, 1) * (1 - sat);
  const eff = strength + (WHITEISH_SHEEN - strength) * whiteness;
  const hi = mixRgb(ink, WHITE, 0.7 * eff);
  const body = darken(ink, bodyDarken * (1 - whiteness));
  const grad = g2.createRadialGradient(
    c - R * 0.35,
    c - R * 0.4,
    R * 0.05,
    c,
    c,
    R * 1.15
  );
  grad.addColorStop(0, rgba(hi, 1));
  grad.addColorStop(0.5, rgba(body, 1));
  grad.addColorStop(1, rgba(body, 0.85));
  g2.fillStyle = grad;
  g2.beginPath();
  g2.arc(c, c, R, 0, Math.PI * 2);
  g2.fill();
  spriteCache.set(key, cv);
  return cv;
};

const sphereFill = (ctx, x, y, r, ink, strength, bodyDarken) => {
  const sprite = sphereSprite(ink, strength, bodyDarken);
  const scale = r / SPRITE_R;
  const drawSize = sprite.width * scale;
  ctx.drawImage(sprite, x - drawSize / 2, y - drawSize / 2, drawSize, drawSize);
};

const rectsOverlap = (a, b) =>
  a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;

const distToSegmentSq = (px, py, x1, y1, x2, y2) => {
  const dx = x2 - x1;
  const dy = y2 - y1;
  const lenSq = dx * dx + dy * dy;
  if (lenSq === 0) return (px - x1) ** 2 + (py - y1) ** 2;
  const u = clamp(((px - x1) * dx + (py - y1) * dy) / lenSq, 0, 1);
  const projX = x1 + u * dx;
  const projY = y1 + u * dy;
  return (px - projX) ** 2 + (py - projY) ** 2;
};

const ruDateFormatter = new Intl.DateTimeFormat('ru-RU', {
  day: 'numeric',
  month: 'short',
  year: 'numeric',
});

const formatRuDate = tsSeconds => {
  if (!tsSeconds) return '';
  try {
    return ruDateFormatter.format(new Date(tsSeconds * 1000));
  } catch {
    return '';
  }
};

const wrapText = (ctx, text, maxW) => {
  const words = String(text || '')
    .split(/\s+/)
    .filter(Boolean);
  const lines = [];
  let line = '';
  for (const word of words) {
    const next = line ? `${line} ${word}` : word;
    if (!line || ctx.measureText(next).width <= maxW) {
      line = next;
    } else {
      lines.push(line);
      line = word;
    }
  }
  if (line) lines.push(line);
  return lines.length ? lines : [''];
};

const ellipsize = (ctx, text, maxW) => {
  const str = String(text || '');
  if (ctx.measureText(str).width <= maxW) return str;
  let s = str;
  while (s.length > 1 && ctx.measureText(`${s}…`).width > maxW) {
    s = s.slice(0, -1);
  }
  return `${s.trimEnd()}…`;
};

// ── Domain Classification & Relational Extraction ────────────────────────────
const DOCTOR_PALETTE = {
  stroke: '#3b82f6',
  chip: 'bg-n-blue-3/70 text-n-blue-11 border-n-blue-6',
  dot: '#3b82f6',
};

const SERVICE_PALETTE = {
  stroke: '#10b981',
  chip: 'bg-n-teal-3/70 text-n-teal-11 border-n-teal-6',
  dot: '#10b981',
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
      'онлайн',
    ],
    palette: {
      stroke: '#8b5cf6',
      chip: 'bg-n-violet-3/70 text-n-violet-11 border-n-violet-6',
      dot: '#8b5cf6',
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
      chip: 'bg-n-ruby-3/70 text-n-ruby-11 border-n-ruby-6',
      dot: '#ec4899',
    },
  },
  {
    key: 'documents',
    i18nKey: 'DOCUMENTS',
    icon: 'i-lucide-file-check-2',
    keywords: [
      'справк',
      'больничн',
      'документ',
      'выписк',
      'договор',
      'страхов',
      'осмс',
      'гобмп',
      'удостоверен',
      'паспорт',
      'рецепт',
      'направлен',
    ],
    palette: {
      stroke: '#06b6d4',
      chip: 'bg-n-iris-3/70 text-n-iris-11 border-n-iris-6',
      dot: '#06b6d4',
    },
  },
];

const DEFAULT_CLUSTER = {
  key: 'general',
  i18nKey: 'GENERAL',
  icon: 'i-lucide-sparkles',
  palette: {
    stroke: '#64748b',
    chip: 'bg-n-slate-3/80 text-n-slate-11 border-n-slate-6',
    dot: '#64748b',
  },
};

const STOP_WORDS = new Set([
  'как',
  'что',
  'для',
  'или',
  'при',
  'это',
  'все',
  'вас',
  'нам',
  'вам',
  'его',
  'ее',
  'они',
  'мы',
  'вы',
  'есть',
  'нет',
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

const truncateText = (value, maxLength = 38) => {
  const clean = String(value || '').trim();
  if (clean.length <= maxLength) return clean;
  return `${clean.slice(0, maxLength - 1)}…`;
};

const formatPriceKzt = price => {
  const num = Number(price);
  if (!Number.isFinite(num) || num <= 0) return '';
  return `${num.toLocaleString('ru-RU')} ₸`;
};

const parseTimestampSec = raw => {
  if (!raw) return null;
  const ms = Date.parse(raw);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : null;
};

const detectDarkMode = () => {
  if (typeof document === 'undefined') return false;
  return (
    document.body?.classList.contains('dark') ||
    document.documentElement?.classList.contains('dark')
  );
};

// ── Reactive UI State ────────────────────────────────────────────────────────
const activeClusterKey = ref('all');
const selectedNodeId = ref(null);
const inspectorOpen = ref(false);
const isFullscreen = ref(false);
const copiedAnswer = ref(false);
const isDarkTheme = ref(detectDarkMode());

const wrapRef = ref(null);
const canvasRef = ref(null);

const simNodes = shallowRef([]);
const simEdges = shallowRef([]);

// Non-reactive canvas loop state for 0-lag rendering
const nodesRef = { current: [] };
const linksRef = { current: [] };
const byIdRef = { current: new Map() };
const adjacencyRef = { current: new Map() };
const ringsRef = { current: [] };
const ringLabelRectsRef = { current: [] };
const viewportRef = { current: { k: 1, x: 540, y: 320 } };
const sizeRef = { current: { w: 1080, h: 640 } };
const dprRef = { current: 1 };
const hoverIdRef = { current: null };
const hoverRingRef = { current: null };
const hoverLinkRef = { current: null };
const selectedRingRef = { current: null };
const dirtyRef = { current: true };
const paletteRef = { current: null };
const simInstanceRef = { current: null };
const invalidateRef = { current: () => {} };
const dragRef = {
  current: {
    mode: 'none',
    id: null,
    ring: null,
    moved: false,
    sx: 0,
    sy: 0,
    vp: { k: 1, x: 0, y: 0 },
  },
};

const fadeBuckets = {
  appear: new Map(),
  labels: new Map(),
  links: new Map(),
  nodes: new Map(),
  rings: new Map(),
};

const resetFades = () => {
  Object.values(fadeBuckets).forEach(b => b.clear());
};

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
      shortQuestion: truncateText(question, 42),
      answer,
      clusterKey: cluster.key,
      clusterLabel: t(`CAPTAIN.KNOWLEDGE_BASE.GRAPH.TOPICS.${cluster.i18nKey}`),
      clusterIcon: cluster.icon,
      palette: cluster.palette,
      docName: docName ? truncateText(docName, 26) : null,
      timestamp: parseTimestampSec(item.created_at || item.updated_at),
      tokens: extractTokens(`${question} ${answer}`),
    };
  })
);

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
      raw: doc,
      timestamp: parseTimestampSec(doc.created_at || doc.updated_at),
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
      timestamp: parseTimestampSec(srv.created_at || srv.updated_at),
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

const hasClinicEntities = computed(
  () =>
    clinicRelations.value.doctors.length > 0 ||
    clinicRelations.value.services.length > 0
);

const clusters = computed(() => {
  const map = new Map();
  normalizedFaqs.value.forEach(item => {
    if (!map.has(item.clusterKey)) {
      map.set(item.clusterKey, {
        key: item.clusterKey,
        label: item.clusterLabel,
        icon: item.clusterIcon,
        palette: item.palette,
        count: 0,
      });
    }
    map.get(item.clusterKey).count += 1;
  });
  return Array.from(map.values()).sort((a, b) => b.count - a.count);
});

const selectableNodes = computed(() =>
  simNodes.value.filter(n => ['faq', 'doctor', 'service'].includes(n.kind))
);

const faqNodes = computed(() => selectableNodes.value);

const selectedNode = computed(() => {
  if (!selectableNodes.value.length) return null;
  return (
    selectableNodes.value.find(node => node.rawId === selectedNodeId.value) ||
    selectableNodes.value[0]
  );
});

const semanticPeers = computed(() => {
  if (!selectedNode.value) return [];
  const currentId = selectedNode.value.id;
  const peerIds = new Set();
  simEdges.value.forEach(edge => {
    if (edge.sourceId === currentId) peerIds.add(edge.targetId);
    if (edge.targetId === currentId) peerIds.add(edge.sourceId);
  });
  return selectableNodes.value
    .filter(n => peerIds.has(n.id) && n.id !== currentId)
    .slice(0, 6);
});

// ── Build Hermes Starmap Graph & Simulation ──────────────────────────────────
const buildStarmapSimulation = () => {
  const q = normalizedQuery.value;
  const filterKey = activeClusterKey.value;

  const showClinic =
    filterKey === 'all' ||
    filterKey === 'clinic' ||
    filterKey === 'only_doctors' ||
    filterKey === 'only_services';
  const showDoctors = showClinic && filterKey !== 'only_services';
  const showServices = showClinic && filterKey !== 'only_doctors';
  const showFaqs =
    filterKey !== 'clinic' &&
    filterKey !== 'only_doctors' &&
    filterKey !== 'only_services';

  const filteredDoctors = showDoctors
    ? clinicRelations.value.doctors.filter(doc => {
        if (!q) return true;
        const serviceNames = doc.linkedServices.map(s => s.name).join(' ');
        return `${doc.name} ${doc.specialty} ${doc.description} ${serviceNames}`
          .toLowerCase()
          .includes(q);
      })
    : [];

  const visibleDoctorIds = new Set(filteredDoctors.map(d => d.id));

  let candidateServices = showServices
    ? clinicRelations.value.services.filter(srv => {
        if (q) {
          const docNames = srv.linkedDoctors.map(d => d.name).join(' ');
          return `${srv.name} ${srv.category} ${srv.description} ${docNames}`
            .toLowerCase()
            .includes(q);
        }
        return true;
      })
    : [];

  // Prioritize services connected to doctors, cap unlinked services so the canvas stays butter-smooth
  const linkedServices = candidateServices.filter(srv =>
    srv.linkedDoctors.some(d => visibleDoctorIds.has(d.resourceId))
  );
  const unlinkedServices = candidateServices.filter(
    srv => !srv.linkedDoctors.some(d => visibleDoctorIds.has(d.resourceId))
  );
  const maxUnlinked = filterKey === 'only_services' ? 120 : 60;
  candidateServices = [
    ...linkedServices,
    ...unlinkedServices.slice(0, maxUnlinked),
  ];

  const visibleServiceIds = new Set(candidateServices.map(s => s.id));

  const filteredFaqs = showFaqs
    ? normalizedFaqs.value.filter(item => {
        const matchesCluster =
          filterKey === 'all' || item.clusterKey === filterKey;
        if (!matchesCluster) return false;
        if (!q) return true;
        return (
          item.question.toLowerCase().includes(q) ||
          item.answer.toLowerCase().includes(q) ||
          (item.docName && item.docName.toLowerCase().includes(q))
        );
      })
    : [];

  const nodes = [];
  const edges = [];

  // Reference date anchor for rings (latest item timestamp or Oct 19, 2026)
  const allTimestamps = [
    ...filteredDoctors.map(d => d.timestamp),
    ...candidateServices.map(s => s.timestamp),
    ...filteredFaqs.map(f => f.timestamp),
  ].filter(Boolean);
  const anchorSec = allTimestamps.length
    ? Math.max(...allTimestamps)
    : Math.floor(Date.now() / 1000);

  // 4 dated concentric shells (matching Hermes Starmap's exact dated ring headers)
  const ringDates = [
    null,
    formatRuDate(anchorSec - 4 * 86400),
    formatRuDate(anchorSec - 2 * 86400),
    formatRuDate(anchorSec - 1 * 86400),
    formatRuDate(anchorSec),
  ];

  const rings = Array.from({ length: RING_STEPS + 1 }, (_, i) => ({
    label: ringDates[i] || null,
    r: ringRadius(i),
    ratio: recForRatio(i / RING_STEPS),
  }));

  // 1. Doctors -> Skill Orbs (Circles) in Inner/Mid Shells (Ring 1 & Ring 2)
  filteredDoctors.forEach((doc, idx) => {
    const totalReceptions = doc.linkedServices.reduce(
      (sum, s) => sum + (s.receptionsCount || 0),
      0
    );
    const useCount = Math.max(
      totalReceptions,
      doc.linkedServices.length * 14,
      6
    );
    const ringIdx = doc.linkedServices.length >= 3 ? 1 : 1 + (idx % 2);
    const summaryLines = [];
    if (doc.specialty) summaryLines.push(`Специальность: ${doc.specialty}`);
    if (doc.slotDurationMin) {
      summaryLines.push(`Длительность приема: ${doc.slotDurationMin} мин`);
    }
    if (doc.description) summaryLines.push(doc.description);
    if (doc.linkedServices.length > 0) {
      const preview = doc.linkedServices
        .slice(0, 8)
        .map(s => {
          const p = formatPriceKzt(s.price);
          return `• ${s.name}${p ? ` — ${p}` : ''}`;
        })
        .join('\n');
      summaryLines.push(
        `Оказываемые услуги (${doc.linkedServices.length}):\n${preview}`
      );
    }

    nodes.push({
      id: doc.nodeId,
      rawId: doc.rawId,
      kind: 'doctor',
      starmapKind: 'skill', // Circle orb with 3D sphereSprite shading
      label: doc.name,
      question: doc.name,
      answer: summaryLines.join('\n\n'),
      categoryTag: (doc.specialty || 'врач').toLowerCase(),
      subTag: 'врач',
      dateLabel: ringDates[ringIdx] || formatRuDate(anchorSec),
      useCount,
      pinned: doc.linkedServices.length >= 4,
      outerRingIndex: ringIdx,
      clusterKey: 'doctors',
      clusterLabel: doc.specialty ? `Врач · ${doc.specialty}` : 'Врач клиники',
      palette: DOCTOR_PALETTE,
      linkedServices: doc.linkedServices,
      raw: doc.raw,
    });
  });

  // Connect Doctors sharing the same specialty so Doctor constellations form naturally
  for (let i = 0; i < filteredDoctors.length; i += 1) {
    for (let j = i + 1; j < filteredDoctors.length; j += 1) {
      const d1 = filteredDoctors[i];
      const d2 = filteredDoctors[j];
      if (
        d1.specialty &&
        d2.specialty &&
        d1.specialty.toLowerCase() === d2.specialty.toLowerCase()
      ) {
        edges.push({
          id: `doc-spec-${d1.id}-${d2.id}`,
          source: d1.nodeId,
          target: d2.nodeId,
          kind: 'specialty',
        });
      }
    }
  }

  // 2. Services -> Memory Diamonds in Mid/Outer Shells (Ring 2, 3, 4)
  candidateServices.forEach((srv, idx) => {
    const connectedDocs = srv.linkedDoctors.filter(d =>
      visibleDoctorIds.has(d.resourceId)
    );
    const totalReceptions = connectedDocs.reduce(
      (sum, d) => sum + (d.receptionsCount || 0),
      0
    );
    const ringIdx = connectedDocs.length > 0 ? 2 + (idx % 2) : 3 + (idx % 2);
    const priceStr = formatPriceKzt(srv.basePrice);
    const summaryLines = [];
    if (srv.category) summaryLines.push(`Категория: ${srv.category}`);
    if (priceStr) summaryLines.push(`Базовая стоимость: ${priceStr}`);
    if (srv.durationMin) {
      summaryLines.push(`Длительность: ${srv.durationMin} мин`);
    }
    if (srv.description) summaryLines.push(srv.description);

    nodes.push({
      id: srv.nodeId,
      rawId: srv.rawId,
      kind: 'service',
      starmapKind: 'memory', // Diamond glyph in complementary teal ink
      label: srv.name,
      question: srv.name,
      answer: summaryLines.join('\n\n'),
      categoryTag: (srv.category || 'услуга').toLowerCase(),
      subTag: priceStr || 'прайс',
      dateLabel: ringDates[ringIdx] || formatRuDate(anchorSec),
      useCount: Math.max(totalReceptions, connectedDocs.length),
      pinned: false,
      outerRingIndex: ringIdx,
      clusterKey: 'pricing',
      clusterLabel: srv.category
        ? `Услуга · ${srv.category}`
        : 'Услуга клиники',
      palette: SERVICE_PALETTE,
      linkedDoctors: srv.linkedDoctors,
      raw: srv.raw,
    });

    connectedDocs.forEach(docRel => {
      edges.push({
        id: `rel-doc-${docRel.resourceId}-srv-${srv.id}`,
        source: `doctor-${docRel.resourceId}`,
        target: srv.nodeId,
        kind: 'doctor_service',
      });
    });
  });

  // Connect services in the same category if unlinked so they form tidy constellations
  const srvByCategory = new Map();
  candidateServices.forEach(srv => {
    const cat = (srv.category || 'general').toLowerCase();
    if (!srvByCategory.has(cat)) srvByCategory.set(cat, []);
    srvByCategory.get(cat).push(srv);
  });
  srvByCategory.forEach(list => {
    for (let i = 0; i + 1 < Math.min(list.length, 10); i += 1) {
      if (list[i].linkedDoctors.length === 0) {
        edges.push({
          id: `srv-cat-${list[i].id}-${list[i + 1].id}`,
          source: list[i].nodeId,
          target: list[i + 1].nodeId,
          kind: 'category',
        });
      }
    }
  });

  // 3. FAQ Knowledge -> Skill Orbs in Rings 2, 3, 4 + Cross-Links to Doctors & Services
  filteredFaqs.forEach((item, idx) => {
    const ringIdx = 2 + (idx % 3); // Rings 2, 3, 4
    let peerLinksCount = 0;

    filteredDoctors.forEach(doc => {
      if (computeJaccard(item.tokens, doc.tokens) >= 0.12) {
        peerLinksCount += 1;
        edges.push({
          id: `sem-faq-doc-${item.id}-${doc.id}`,
          source: item.id,
          target: doc.nodeId,
          kind: 'semantic',
        });
      }
    });

    candidateServices.forEach(srv => {
      if (
        visibleServiceIds.has(srv.id) &&
        computeJaccard(item.tokens, srv.tokens) >= 0.16
      ) {
        peerLinksCount += 1;
        edges.push({
          id: `sem-faq-srv-${item.id}-${srv.id}`,
          source: item.id,
          target: srv.nodeId,
          kind: 'semantic',
        });
      }
    });

    nodes.push({
      id: item.id,
      rawId: item.rawId,
      kind: 'faq',
      starmapKind: 'skill',
      label: item.shortQuestion,
      question: item.question,
      answer: item.answer,
      categoryTag: item.clusterKey,
      subTag: 'learned',
      dateLabel: ringDates[ringIdx] || formatRuDate(anchorSec),
      useCount: Math.max(1, peerLinksCount * 4 + ((idx * 7) % 19)),
      pinned: Boolean(item.docName),
      outerRingIndex: ringIdx,
      clusterKey: item.clusterKey,
      clusterLabel: item.clusterLabel,
      docName: item.docName,
      palette: item.palette,
      raw: item.raw,
    });
  });

  // Semantic & cluster links between FAQs
  for (let i = 0; i < filteredFaqs.length; i += 1) {
    let bestPeer = null;
    let bestScore = 0;
    for (let j = i + 1; j < filteredFaqs.length; j += 1) {
      const sameCluster =
        filteredFaqs[i].clusterKey === filteredFaqs[j].clusterKey;
      const score =
        computeJaccard(filteredFaqs[i].tokens, filteredFaqs[j].tokens) +
        (sameCluster ? 0.12 : 0);
      if (score > bestScore && score >= 0.12) {
        bestScore = score;
        bestPeer = filteredFaqs[j];
      }
    }
    if (bestPeer) {
      edges.push({
        id: `sem-${filteredFaqs[i].id}-${bestPeer.id}`,
        source: filteredFaqs[i].id,
        target: bestPeer.id,
        kind: 'semantic',
      });
    }
  }

  // Assign radial target `tr` and `rec` per node (exact Hermes simulation.ts logic)
  const simNodesList = nodes.map(n => {
    const ringIdx = clamp(n.outerRingIndex || 2, 1, RING_STEPS);
    const tr = placeRadius(ringIdx, n.id);
    const hi = rings[ringIdx]?.ratio ?? 1;
    const lo = rings[ringIdx - 1]?.ratio ?? 0;
    const jitter = ((hash(n.id) % 100) / 100) * 0.8 + 0.1;
    const rec = lo + jitter * (hi - lo);
    const angle = ((hash(n.id) % 3600) / 3600) * Math.PI * 2;
    return {
      ...n,
      rec,
      tr,
      vx: 0,
      vy: 0,
      x: Math.cos(angle) * tr,
      y: Math.sin(angle) * tr,
    };
  });

  const byId = new Map(simNodesList.map(n => [n.id, n]));
  const validLinks = edges
    .filter(e => byId.has(e.source) && byId.has(e.target))
    .map(e => ({
      id: e.id,
      kind: e.kind,
      source: e.source,
      target: e.target,
    }));

  const adjacency = new Map();
  simNodesList.forEach(n => adjacency.set(n.id, new Set()));
  validLinks.forEach(e => {
    adjacency.get(e.source)?.add(e.target);
    adjacency.get(e.target)?.add(e.source);
  });

  if (simInstanceRef.current) {
    simInstanceRef.current.stop();
  }

  // Pre-settle 45 ticks synchronously so unit tests & first paint have immediate coordinates,
  // then let d3-force finish smoothly if needed
  const sim = forceSimulation(simNodesList)
    .alphaDecay(0.06)
    .velocityDecay(0.62)
    .force('charge', forceManyBody().strength(-14))
    .force(
      'link',
      forceLink(validLinks)
        .id(n => n.id)
        .distance(28)
        .strength(0.06)
    )
    .force(
      'collide',
      forceCollide()
        .radius(n => nodeRadius(n) + 2.5)
        .iterations(2)
    )
    .force('radial', forceRadial(n => n.tr, 0, 0).strength(0.92))
    .stop();

  sim.tick(70);

  nodesRef.current = simNodesList;
  linksRef.current = validLinks;
  byIdRef.current = byId;
  adjacencyRef.current = adjacency;
  ringsRef.current = rings;
  simInstanceRef.current = sim;

  simNodes.value = simNodesList;
  simEdges.value = validLinks.map(l => ({
    id: l.id,
    kind: l.kind,
    sourceId: typeof l.source === 'object' ? l.source.id : l.source,
    targetId: typeof l.target === 'object' ? l.target.id : l.target,
  }));

  resetFades();
  if (sizeRef.current.w > 0 && sizeRef.current.h > 0) {
    viewportRef.current = fitViewport(
      sizeRef.current.w,
      sizeRef.current.h,
      rings[rings.length - 1]?.r ?? RING_OUTER
    );
  }
  invalidateRef.current();
};

// ── Hermes Starmap Pure 2D Canvas Renderers (drawScene + drawScramble) ──────
const drawScene = ({
  ctx,
  dpr,
  palette,
  vp,
  size,
  nodes,
  links,
  byId,
  adjacency,
  rings,
  focusId,
  hoverId,
  hoverRing,
  hoverLink,
  selectedRing,
}) => {
  const { w, h } = size;
  const {
    bandInk,
    base,
    bg,
    c,
    chipBg,
    darkTheme,
    inkInv,
    memoryInk,
    skillInk,
  } = palette;
  const { bandAlpha, lightSize, ringAlpha, sheen } =
    RING_PARAMS[darkTheme ? 'dark' : 'light'];

  let animating = false;
  const ringLabelRects = [];

  const fadeAlpha = (bucket, key, target, snapUp = false) => {
    const targetAlpha = clamp(target, 0, 1);
    const prev = bucket.get(key);
    if (prev == null || (snapUp && targetAlpha > prev)) {
      bucket.set(key, targetAlpha);
      return targetAlpha;
    }
    const rate = targetAlpha > prev ? 0.25 : 0.34;
    const next = prev + (targetAlpha - prev) * rate;
    if (Math.abs(next - targetAlpha) < 0.01) {
      bucket.set(key, targetAlpha);
      return targetAlpha;
    }
    animating = true;
    bucket.set(key, next);
    return next;
  };

  const shade = a => `rgba(${base.r},${base.g},${base.b},${a})`;
  const projX = wx => wx * vp.k + vp.x;
  const projY = wy => wy * vp.k * TILT + vp.y;
  const nodeK = fitScale(w, h, rings);

  const focusSet = focusId ? (adjacency.get(focusId) ?? new Set()) : null;
  const ringIdx = selectedRing;
  const ring = ringIdx != null ? (rings[ringIdx] ?? null) : null;
  const ringLo =
    ring && ringIdx != null ? (rings[ringIdx - 1]?.ratio ?? 0) - 1e-3 : 0;
  const ringHi = ring ? ring.ratio + 1e-3 : 1;

  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  ctx.globalAlpha = 1;

  // World transform for concentric rings & radial bands
  ctx.setTransform(vp.k * dpr, 0, 0, vp.k * TILT * dpr, vp.x * dpr, vp.y * dpr);

  const litRingIdx = hoverRing ?? ringIdx;

  if (bandAlpha > 0 || litRingIdx != null) {
    for (let i = 0; i < rings.length - 1; i += 1) {
      const lit = litRingIdx != null && i + 1 === litRingIdx;
      const inner = rings[i]?.r ?? 0;
      const outer = rings[i + 1]?.r ?? 0;

      if (lit) {
        ctx.fillStyle = rgba(bandInk, LIT_BAND_ALPHA);
      } else {
        const grad = ctx.createRadialGradient(0, 0, inner, 0, 0, outer);
        if (darkTheme) {
          grad.addColorStop(0, rgba(bandInk, 0));
          grad.addColorStop(clamp(1 - lightSize, 0.01, 0.99), rgba(bandInk, 0));
          grad.addColorStop(1, rgba(bandInk, bandAlpha));
        } else {
          grad.addColorStop(0, rgba(bandInk, bandAlpha));
          grad.addColorStop(clamp(lightSize, 0.01, 0.99), rgba(bandInk, 0));
          grad.addColorStop(1, rgba(bandInk, 0));
        }
        ctx.fillStyle = grad;
      }

      ctx.beginPath();
      ctx.arc(0, 0, outer, 0, Math.PI * 2);
      ctx.arc(0, 0, inner, 0, Math.PI * 2, true);
      ctx.fill();
    }
  }

  // Concentric Ring Outlines
  ctx.lineWidth = c.ringWidth / vp.k;
  ctx.setLineDash([]);
  rings.forEach((rg, i) => {
    const emphasized = ringIdx != null && (i === ringIdx || i === ringIdx - 1);
    const emphasisAlpha = emphasized
      ? clamp(LIT_BAND_ALPHA * 2.2, 0, 1)
      : ringAlpha;
    const ringAlphaNow = fadeAlpha(
      fadeBuckets.rings,
      String(i),
      emphasisAlpha,
      emphasized
    );
    if (ringAlphaNow < 0.004) return;
    ctx.strokeStyle = shade(ringAlphaNow);
    ctx.beginPath();
    ctx.arc(0, 0, rg.r, 0, Math.PI * 2);
    ctx.stroke();
  });

  // Screen space for links, nodes, ring labels, and callout boxes
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  const focusNode = focusId ? (byId.get(focusId) ?? null) : null;
  const focusRingR = focusNode ? nodeRadius(focusNode) * nodeK + 4 : 0;

  for (const link of links) {
    const s =
      typeof link.source === 'object'
        ? link.source
        : byId.get(String(link.source));
    const tNode =
      typeof link.target === 'object'
        ? link.target
        : byId.get(String(link.target));
    if (!s || !tNode) continue;

    const lit =
      Boolean(focusId) &&
      (s.id === focusId ||
        tNode.id === focusId ||
        (Boolean(focusSet) && focusSet.has(s.id) && focusSet.has(tNode.id)));

    let x1 = projX(s.x);
    let y1 = projY(s.y);
    let x2 = projX(tNode.x);
    let y2 = projY(tNode.y);

    if (s.id === focusId) {
      const d = Math.hypot(x2 - x1, y2 - y1) || 1;
      x1 += ((x2 - x1) / d) * focusRingR;
      y1 += ((y2 - y1) / d) * focusRingR;
    }
    if (tNode.id === focusId) {
      const d = Math.hypot(x1 - x2, y1 - y2) || 1;
      x2 += ((x1 - x2) / d) * focusRingR;
      y2 += ((y1 - y2) / d) * focusRingR;
    }

    const key = `${s.id}->${tNode.id}`;
    const ambient = recencyInk((s.rec + tNode.rec) / 2) * c.lineAlpha;
    const targetAlpha = lit
      ? 1
      : key === hoverLink
        ? clamp(ambient * 2, 0, 0.7)
        : focusId || ring
          ? 0.025
          : ambient;

    const linkAlpha = fadeAlpha(fadeBuckets.links, key, targetAlpha, lit);
    if (linkAlpha < 0.004) continue;

    ctx.strokeStyle = shade(linkAlpha);
    ctx.setLineDash(lit || !c.lineDashed ? [] : [c.lineDash, c.lineDash]);
    ctx.lineWidth = lit ? 1.5 : c.lineWidth;
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x2, y2);
    ctx.stroke();
  }
  ctx.setLineDash([]);

  // Nodes (3D-shaded sphereSprite circles + memoryInk diamonds)
  const revealedRings = new Set();
  for (const n of nodes) {
    revealedRings.add(n.outerRingIndex);
    const isFocus = n.id === focusId;
    const isNeighbor = Boolean(focusSet) && focusSet.has(n.id);
    const inRing = Boolean(ring) && n.rec >= ringLo && n.rec < ringHi;
    const nodeHigh = isFocus || isNeighbor;
    const ageScale =
      nodeHigh || inRing ? 1 : 0.38 + Math.min(1, n.rec / 0.4) * 0.62;
    const r = nodeRadius(n) * nodeK * ageScale;

    const baseAlpha = nodeHigh
      ? 1
      : ring
        ? inRing
          ? focusId
            ? 0.55
            : 1
          : 0.16
        : focusId
          ? 0.16
          : recencyInk(n.rec);

    const vis = fadeAlpha(
      fadeBuckets.nodes,
      n.id,
      baseAlpha,
      nodeHigh || inRing
    );
    if (vis < 0.004) continue;

    const sx = projX(n.x);
    const sy = projY(n.y);

    ctx.globalAlpha = vis;
    const nodeInk = nodeHigh
      ? base
      : n.starmapKind === 'memory'
        ? memoryInk
        : skillInk;
    const shape = n.starmapKind === 'memory' ? 'diamond' : 'circle';

    if (shape === 'circle') {
      sphereFill(ctx, sx, sy, r, nodeInk, sheen, nodeHigh ? 0 : ORB_DARKEN);
    } else {
      shapePath(ctx, shape, sx, sy, r);
      ctx.fillStyle = rgba(nodeInk, 1);
      ctx.fill();
    }

    if (isFocus) {
      ctx.globalAlpha = 1;
      ctx.strokeStyle = rgba(nodeInk, 1);
      ctx.lineWidth = 1.4;
      shapePath(ctx, shape, sx, sy, r + 4);
      ctx.stroke();
    }
  }

  ctx.globalAlpha = 1;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  // Ring Date Labels at 12 o'clock on each concentric ellipse
  ctx.font = '10px ui-sans-serif, system-ui, sans-serif';
  ctx.textAlign = 'center';
  const LABEL_GAP = 15;
  let lastLabelY = Number.POSITIVE_INFINITY;

  rings.forEach((rg, i) => {
    if (!rg.label || !revealedRings.has(i)) return;
    const sx = projX(0);
    const sy = projY(-rg.r);
    if (sy < 8 || sy > h - 8 || lastLabelY - sy < LABEL_GAP) return;

    lastLabelY = sy;
    const tw = ctx.measureText(rg.label).width;
    const boxW = tw + 6;
    const isThis = ringIdx === i || hoverRing === i;
    const faded = (focusId != null || ringIdx != null) && !isThis;
    const labelAlpha = fadeAlpha(
      fadeBuckets.labels,
      String(i),
      faded ? 0.33 : 1,
      isThis
    );
    if (labelAlpha < 0.01) return;

    ctx.globalAlpha = labelAlpha;
    ctx.fillStyle = rgba(bg, 1);
    ctx.fillRect(sx - boxW / 2, sy - 6, boxW, 13);
    ctx.fillStyle = shade(isThis ? 1 : 0.24);
    ctx.fillText(rg.label, sx, sy + 3);
    ctx.globalAlpha = 1;
    ringLabelRects.push({
      h: 18,
      i,
      w: boxW + 6,
      x: sx - boxW / 2 - 3,
      y: sy - 10,
    });
  });

  // Focused Node Inverted Tooltip Box (exact Hermes Starmap callout)
  const tip = focusId ? byId.get(focusId) : null;
  let tipRect = null;

  if (tip) {
    const PADX = 6;
    const PADY = 4;
    const BADGE_H = 14;
    const ROW_GAP = 3;
    const LINE_H = 16;
    const ITEM_GAP = 8;
    const badgeFont = '9px ui-sans-serif, system-ui, sans-serif';
    const monoFont = '9px ui-monospace, SFMono-Regular, Menlo, monospace';
    const titleFont = '600 11px ui-sans-serif, system-ui, sans-serif';
    const badgeFontFor = i => (i === 0 ? badgeFont : monoFont);

    const badges = [tip.dateLabel, tip.categoryTag, tip.subTag].filter(Boolean);
    const use = tip.useCount > 0 ? `x${tip.useCount}` : null;
    const titleText = tip.label || tip.question;

    const badgeW = badges.map((b, i) => {
      ctx.font = badgeFontFor(i);
      return ctx.measureText(b).width;
    });

    const rowW =
      badgeW.reduce((a, b) => a + b, 0) +
      ITEM_GAP * Math.max(0, badges.length - 1);
    ctx.font = monoFont;
    const useW = use ? ctx.measureText(use).width : 0;
    const metaW = rowW + (use ? ITEM_GAP + useW : 0);

    ctx.font = titleFont;
    const maxTitleW = Math.min(380, w - 16) - PADX * 2;
    const titleLines = wrapText(ctx, titleText, maxTitleW);
    const titleW = Math.max(
      0,
      ...titleLines.map(l => ctx.measureText(l).width)
    );
    const titleBgW = titleW + PADX * 2;
    const titleBgH = titleLines.length * LINE_H + PADY * 2;

    const totalW = Math.max(metaW, titleBgW);
    const totalH = BADGE_H + ROW_GAP + titleBgH;
    const bx = clamp(projX(tip.x) - totalW / 2, 8, Math.max(8, w - totalW - 8));
    const by = clamp(
      projY(tip.y) - (nodeRadius(tip) * nodeK + 8) - totalH,
      8,
      Math.max(8, h - totalH - 8)
    );
    tipRect = { h: totalH, w: totalW, x: bx, y: by };

    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    const badgeMidY = by + BADGE_H / 2;

    ctx.fillStyle = shade(0.7);
    let cx = bx;
    badges.forEach((label, i) => {
      ctx.font = badgeFontFor(i);
      ctx.fillText(label, cx, badgeMidY);
      cx += badgeW[i] + ITEM_GAP;
    });

    if (use) {
      ctx.font = monoFont;
      ctx.fillStyle = shade(0.5);
      ctx.fillText(use, cx, badgeMidY);
    }

    // Inverted title box (white box + black text in dark mode)
    const ty = by + BADGE_H + ROW_GAP;
    ctx.fillStyle = shade(1);
    ctx.fillRect(bx, ty, titleBgW, titleBgH);
    ctx.font = titleFont;
    ctx.fillStyle = inkInv;
    titleLines.forEach((line, i) => {
      ctx.fillText(line, bx + PADX, ty + PADY + LINE_H * i + LINE_H / 2);
    });
    ctx.textBaseline = 'alphabetic';
  }

  // Neighbor Constellation Labels (greedy collision-free placement)
  ctx.font = '11px ui-sans-serif, system-ui, sans-serif';
  ctx.textAlign = 'center';
  const LBL_M = 6;
  const LBL_H = 15;
  const placed = ringLabelRects.map(r => ({
    h: r.h,
    w: r.w,
    x: r.x,
    y: r.y,
  }));
  if (tipRect) placed.push(tipRect);

  for (const id of focusSet ?? []) {
    if (id === hoverId || id === focusId) continue;
    const n = byId.get(id);
    if (!n) continue;

    const label = ellipsize(ctx, n.label, Math.min(185, w * 0.32));
    const bw = ctx.measureText(label).width + 8;
    const x = clamp(
      projX(n.x) - bw / 2,
      LBL_M,
      Math.max(LBL_M, w - bw - LBL_M)
    );
    const top = projY(n.y) - (nodeRadius(n) * nodeK + 7) - LBL_H + 4;
    const clampY = v => clamp(v, LBL_M, Math.max(LBL_M, h - LBL_H - LBL_M));
    const step = LBL_H + 3;
    let y = null;

    for (let k = 0; k <= 7 && y == null; k += 1) {
      for (const dy of k === 0 ? [0] : [-k * step, k * step]) {
        const cand = { h: LBL_H, w: bw, x, y: clampY(top + dy) };
        if (!placed.some(p => rectsOverlap(cand, p))) {
          y = cand.y;
          break;
        }
      }
    }
    if (y == null) continue;

    placed.push({ h: LBL_H, w: bw, x, y });
    ctx.fillStyle = chipBg;
    ctx.fillRect(x, y, bw, LBL_H);
    ctx.fillStyle = shade(0.85);
    ctx.fillText(label, x + bw / 2, y + 11);
  }

  return { animating, ringLabelRects };
};

const drawScramble = ({ ctx, dpr, palette, rings, vp }) => {
  const { bg, darkTheme, primary } = palette;
  const projX = wx => wx * vp.k + vp.x;
  const projY = wy => wy * vp.k * TILT + vp.y;

  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const coreX = projX(0);
  const coreY = projY(0);
  const coreRx = (rings[0]?.r ?? RING_INNER) * vp.k * 1.25;
  if (coreRx <= 0) return;

  const washR = coreRx * 1.15;
  ctx.save();
  ctx.translate(coreX, coreY);
  ctx.scale(1, TILT);
  const wash = ctx.createRadialGradient(0, 0, 0, 0, 0, washR);
  wash.addColorStop(0, rgba(bg, darkTheme ? 0.9 : 0.93));
  wash.addColorStop(0.62, rgba(bg, darkTheme ? 0.84 : 0.88));
  wash.addColorStop(1, rgba(bg, 0));
  ctx.fillStyle = wash;
  ctx.beginPath();
  ctx.arc(0, 0, washR, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

  const cell = clamp(
    coreRx / SCRAMBLE_RADIUS,
    SCRAMBLE_CELL_MIN,
    SCRAMBLE_CELL_MAX
  );
  const coreRy = coreRx * TILT;
  const half = Math.max(3, Math.round(coreRx / cell));
  const now = performance.now();
  const tSec = now / 1000;

  ctx.save();
  ctx.font = `${cell}px "JetBrains Mono", "Hiragino Sans", "Noto Sans JP", ui-monospace, monospace`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';

  for (let r = -half; r <= half; r += 1) {
    // eslint-disable-next-line no-bitwise
    const rowSeed = (r * 19349663) >>> 0 || 1;
    // eslint-disable-next-line no-bitwise
    const dir = rowSeed & 1 ? 1 : -1;
    const speed = 8 + (rowSeed % 16);
    const scroll = (now / 1000) * speed * dir;
    const ny = (r * cell) / coreRy;
    const rowDim = 1 - 0.5 * Math.min(1, Math.abs(ny));
    const kMin = Math.floor((-coreRx - scroll) / cell) - 1;
    const kMax = Math.ceil((coreRx - scroll) / cell) + 1;

    for (let k = kMin; k <= kMax; k += 1) {
      const sx = k * cell + scroll;
      const nx = sx / coreRx;
      const d2 = nx * nx + ny * ny;
      if (d2 > 1) continue;

      // eslint-disable-next-line no-bitwise
      const seed = (rowSeed ^ ((k >>> 0) * 73856093)) >>> 0;
      const ch = SCRAMBLE_CHARS[seed % SCRAMBLE_CHARS.length] ?? '0';
      const edge = clamp((1 - Math.sqrt(d2)) / 0.4, 0, 1);
      // eslint-disable-next-line no-bitwise
      const flick = 0.7 + 0.3 * (((seed >>> 5) % 100) / 100);
      // eslint-disable-next-line no-bitwise
      const phase = (seed & 7) * 0.35;
      const glow =
        Math.sin(nx * 4.5 + tSec * 1.3 + phase) *
        Math.sin(ny * 4.5 - tSec * 0.9 + phase);
      const pop = 1 + clamp((glow - 0.25) / 0.75, 0, 1) * 2.6;
      const a = clamp(
        (darkTheme ? 0.22 : 0.3) * edge * flick * rowDim * pop,
        0,
        0.9
      );
      if (a < 0.02) continue;

      ctx.fillStyle = rgba(primary, a);
      ctx.fillText(ch, coreX + sx, coreY + r * cell);
    }
  }

  ctx.restore();
  ctx.globalAlpha = 1;
};

// ── Hit-Testing & Pointer Events ─────────────────────────────────────────────
const pickNode = (cssX, cssY) => {
  const vp = viewportRef.current;
  const nodeK = fitScale(
    sizeRef.current.w,
    sizeRef.current.h,
    ringsRef.current
  );
  let best = null;
  let bestD = Infinity;

  for (const n of nodesRef.current) {
    const r = nodeRadius(n) * nodeK + 6;
    const sx = n.x * vp.k + vp.x;
    const sy = n.y * vp.k * TILT + vp.y;
    const d = (sx - cssX) ** 2 + (sy - cssY) ** 2;
    if (d < r * r && d < bestD) {
      bestD = d;
      best = n;
    }
  }
  return best;
};

const pickLink = (cssX, cssY) => {
  const vp = viewportRef.current;
  let best = null;
  let bestD = 25;

  for (const link of linksRef.current) {
    const s =
      typeof link.source === 'object'
        ? link.source
        : byIdRef.current.get(String(link.source));
    const tNode =
      typeof link.target === 'object'
        ? link.target
        : byIdRef.current.get(String(link.target));
    if (!s || !tNode) continue;

    const d = distToSegmentSq(
      cssX,
      cssY,
      s.x * vp.k + vp.x,
      s.y * vp.k * TILT + vp.y,
      tNode.x * vp.k + vp.x,
      tNode.y * vp.k * TILT + vp.y
    );
    if (d < bestD) {
      bestD = d;
      best = `${s.id}->${tNode.id}`;
    }
  }
  return best;
};

const pickRingLabel = (cssX, cssY) => {
  for (const r of ringLabelRectsRef.current) {
    if (cssX >= r.x && cssX <= r.x + r.w && cssY >= r.y && cssY <= r.y + r.h) {
      return r.i;
    }
  }
  return null;
};

const localXY = e => {
  const rect = canvasRef.value?.getBoundingClientRect();
  return {
    x: e.clientX - (rect?.left ?? 0),
    y: e.clientY - (rect?.top ?? 0),
  };
};

const onMouseDown = e => {
  if (e.button !== 0) return;
  const { x, y } = localXY(e);
  const ringHit = pickRingLabel(x, y);
  hoverRingRef.current = null;
  const nodeHit = ringHit == null ? pickNode(x, y) : null;
  dragRef.current = {
    mode: 'pan',
    id: nodeHit?.id ?? null,
    rawId: nodeHit?.rawId ?? null,
    ring: ringHit,
    moved: false,
    sx: e.clientX,
    sy: e.clientY,
    vp: { ...viewportRef.current },
  };
};

const onMouseMove = e => {
  const drag = dragRef.current;
  if (drag.mode === 'none') {
    const { x, y } = localXY(e);
    const ringHit = pickRingLabel(x, y);
    const nodeHit = ringHit == null ? pickNode(x, y) : null;
    const id = nodeHit?.id ?? null;
    const linkKey = ringHit == null && id == null ? pickLink(x, y) : null;

    if (
      id !== hoverIdRef.current ||
      ringHit !== hoverRingRef.current ||
      linkKey !== hoverLinkRef.current
    ) {
      hoverIdRef.current = id;
      hoverRingRef.current = ringHit;
      hoverLinkRef.current = linkKey;
      invalidateRef.current();
    }
    return;
  }

  const dx = e.clientX - drag.sx;
  const dy = e.clientY - drag.sy;
  if (Math.abs(dx) > 3 || Math.abs(dy) > 3) {
    drag.moved = true;
  }
  if (drag.mode === 'pan') {
    viewportRef.current = {
      ...drag.vp,
      x: drag.vp.x + dx,
      y: drag.vp.y + dy,
    };
    invalidateRef.current();
  }
};

const endDrag = () => {
  const drag = dragRef.current;
  if (drag.mode === 'pan' && !drag.moved) {
    if (drag.ring != null) {
      selectedRingRef.current =
        selectedRingRef.current === drag.ring ? null : drag.ring;
    } else if (drag.rawId != null) {
      if (selectedNodeId.value === drag.rawId && inspectorOpen.value) {
        inspectorOpen.value = false;
        selectedNodeId.value = null;
      } else {
        selectedNodeId.value = drag.rawId;
        inspectorOpen.value = true;
      }
    } else {
      selectedRingRef.current = null;
      inspectorOpen.value = false;
    }
    invalidateRef.current();
  }
  dragRef.current = {
    mode: 'none',
    id: null,
    rawId: null,
    ring: null,
    moved: false,
    sx: 0,
    sy: 0,
    vp: viewportRef.current,
  };
};

const onMouseLeave = () => {
  hoverIdRef.current = null;
  hoverRingRef.current = null;
  hoverLinkRef.current = null;
  invalidateRef.current();
  endDrag();
};

const onWheel = e => {
  const rect = canvasRef.value?.getBoundingClientRect();
  if (!rect) return;
  const px = e.clientX - rect.left;
  const py = e.clientY - rect.top;
  const vp = viewportRef.current;
  const k = clamp(vp.k * (e.deltaY > 0 ? 0.9 : 1.1), ZOOM_MIN, ZOOM_MAX);
  viewportRef.current = {
    k,
    x: px - ((px - vp.x) / vp.k) * k,
    y: py - ((py - vp.y) / vp.k) * k,
  };
  invalidateRef.current();
};

const resetCamera = () => {
  selectedRingRef.current = null;
  viewportRef.current = fitViewport(
    sizeRef.current.w,
    sizeRef.current.h,
    ringsRef.current[ringsRef.current.length - 1]?.r ?? RING_OUTER
  );
  invalidateRef.current();
};

const zoomCamera = factor => {
  const { w, h } = sizeRef.current;
  const cx = w / 2;
  const cy = h / 2;
  const vp = viewportRef.current;
  const k = clamp(vp.k * factor, ZOOM_MIN, ZOOM_MAX);
  viewportRef.current = {
    k,
    x: cx - ((cx - vp.x) / vp.k) * k,
    y: cy - ((cy - vp.y) / vp.k) * k,
  };
  invalidateRef.current();
};

const selectNode = rawId => {
  selectedNodeId.value = rawId;
  inspectorOpen.value = true;
  invalidateRef.current();
};

const selectCluster = key => {
  activeClusterKey.value =
    activeClusterKey.value === key && key !== 'all' ? 'all' : key;
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

// Build initial deterministic state immediately so unit tests have nodes on mount
buildStarmapSimulation();

watch(
  [
    () => props.responses,
    () => props.doctors,
    () => props.services,
    () => props.serviceStats,
    () => props.searchQuery,
    activeClusterKey,
  ],
  () => {
    buildStarmapSimulation();
  }
);

watch(
  selectableNodes,
  nodes => {
    if (!nodes.length) {
      selectedNodeId.value = null;
      return;
    }
    if (!nodes.some(n => n.rawId === selectedNodeId.value)) {
      selectedNodeId.value = nodes[0].rawId;
    }
  },
  { immediate: true }
);

let rafId = 0;
let resizeObserver = null;
let themeObserver = null;

onMounted(() => {
  const wrap = wrapRef.value;
  const canvas = canvasRef.value;
  if (!wrap || !canvas) return;

  const syncSize = () => {
    const w = wrap.clientWidth || 1080;
    const h = wrap.clientHeight || 640;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    sizeRef.current = { w, h };
    dprRef.current = dpr;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    canvas.style.width = `${w}px`;
    canvas.style.height = `${h}px`;
    viewportRef.current = fitViewport(
      w,
      h,
      ringsRef.current[ringsRef.current.length - 1]?.r ?? RING_OUTER
    );
    dirtyRef.current = true;
    invalidateRef.current();
  };

  if (typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(syncSize);
    resizeObserver.observe(wrap);
  }
  syncSize();

  if (
    typeof MutationObserver !== 'undefined' &&
    typeof document !== 'undefined'
  ) {
    themeObserver = new MutationObserver(() => {
      const nextDark = detectDarkMode();
      if (nextDark !== isDarkTheme.value) {
        isDarkTheme.value = nextDark;
        paletteRef.current = computePalette(nextDark);
        dirtyRef.current = true;
        invalidateRef.current();
      }
    });
    themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['class'],
    });
    if (document.body) {
      themeObserver.observe(document.body, {
        attributes: true,
        attributeFilter: ['class'],
      });
    }
  }

  // Offscreen staticCanvas caching (exact Hermes Starmap 2-layer architecture)
  let staticCanvas = null;
  const ANIM_MS = 1000 / 30;
  let lastAnimTs = 0;
  let force = true;

  const paint = () => {
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    if (!staticCanvas) {
      staticCanvas = document.createElement('canvas');
    }
    if (
      staticCanvas.width !== canvas.width ||
      staticCanvas.height !== canvas.height
    ) {
      staticCanvas.width = canvas.width;
      staticCanvas.height = canvas.height;
      dirtyRef.current = true;
    }

    const offCtx = staticCanvas.getContext('2d');
    if (!offCtx) return;

    if (!paletteRef.current) {
      paletteRef.current = computePalette(isDarkTheme.value);
      dirtyRef.current = true;
    }
    const palette = paletteRef.current;

    const activeSelectedNode =
      inspectorOpen.value && selectedNode.value ? selectedNode.value.id : null;
    const focusId = hoverIdRef.current ?? activeSelectedNode;

    if (dirtyRef.current) {
      const { animating, ringLabelRects } = drawScene({
        ctx: offCtx,
        dpr: dprRef.current,
        palette,
        vp: viewportRef.current,
        size: sizeRef.current,
        nodes: nodesRef.current,
        links: linksRef.current,
        byId: byIdRef.current,
        adjacency: adjacencyRef.current,
        rings: ringsRef.current,
        focusId,
        hoverId: hoverIdRef.current,
        hoverRing: hoverRingRef.current,
        hoverLink: hoverLinkRef.current,
        selectedRing: selectedRingRef.current,
      });
      ringLabelRectsRef.current = ringLabelRects;
      dirtyRef.current = animating;
    }

    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    if (focusId) {
      drawScramble({
        ctx,
        dpr: dprRef.current,
        palette,
        rings: ringsRef.current,
        vp: viewportRef.current,
      });
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.drawImage(staticCanvas, 0, 0);
    } else {
      ctx.drawImage(staticCanvas, 0, 0);
      drawScramble({
        ctx,
        dpr: dprRef.current,
        palette,
        rings: ringsRef.current,
        vp: viewportRef.current,
      });
    }
  };

  const schedule = () => {
    if (!rafId && !document.hidden) {
      rafId = requestAnimationFrame(frame);
    }
  };

  const frame = ts => {
    rafId = 0;
    if (!force && ts - lastAnimTs < ANIM_MS) {
      schedule();
      return;
    }
    force = false;
    lastAnimTs = ts;
    paint();
    schedule();
  };

  invalidateRef.current = () => {
    dirtyRef.current = true;
    force = true;
    schedule();
  };

  schedule();
});

onBeforeUnmount(() => {
  if (rafId) cancelAnimationFrame(rafId);
  if (resizeObserver) resizeObserver.disconnect();
  if (themeObserver) themeObserver.disconnect();
  if (simInstanceRef.current) simInstanceRef.current.stop();
});
</script>

<template>
  <div
    ref="wrapRef"
    class="relative w-full overflow-hidden transition-colors"
    :class="[
      isDarkTheme ? 'bg-[#0a0a0c]' : 'bg-white',
      isFullscreen
        ? 'fixed inset-0 z-50 h-screen w-screen'
        : 'h-[calc(100vh-3.5rem)] min-h-[640px]',
    ]"
  >
    <!-- Hermes Starmap 2-Layer 2D Canvas -->
    <canvas
      ref="canvasRef"
      class="block h-full w-full touch-none select-none"
      data-testid="knowledge-starmap-canvas"
      @dblclick="resetCamera"
      @mousedown="onMouseDown"
      @mousemove="onMouseMove"
      @mouseup="endDrag"
      @mouseleave="onMouseLeave"
      @wheel.prevent="onWheel"
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

    <!-- Top-Left Minimal Topic & Clinic Filter Pills -->
    <div
      v-if="hasClinicEntities || clusters.length > 1"
      class="pointer-events-auto absolute left-4 top-4 z-10 flex max-w-[calc(100%-12rem)] flex-wrap items-center gap-1.5"
    >
      <button
        type="button"
        class="inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium backdrop-blur-md transition-all"
        :class="
          activeClusterKey === 'all'
            ? isDarkTheme
              ? 'border-white/80 bg-white text-black'
              : 'border-slate-900 bg-slate-900 text-white'
            : isDarkTheme
              ? 'border-white/10 bg-black/60 text-neutral-400 hover:border-white/25 hover:text-white'
              : 'border-slate-200 bg-white/85 text-slate-600 hover:border-slate-300 hover:text-slate-950'
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
        class="inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium backdrop-blur-md transition-all"
        :class="
          activeClusterKey === 'clinic'
            ? isDarkTheme
              ? 'border-white/80 bg-white text-black'
              : 'border-slate-900 bg-slate-900 text-white'
            : isDarkTheme
              ? 'border-white/10 bg-black/60 text-neutral-400 hover:border-white/25 hover:text-white'
              : 'border-slate-200 bg-white/85 text-slate-600 hover:border-slate-300 hover:text-slate-950'
        "
        data-testid="knowledge-clinic-links-chip"
        @click="selectCluster('clinic')"
      >
        <span>{{ UI_LABELS.clinicPairs(clinicRelations.pairs.length) }}</span>
      </button>

      <button
        v-if="clinicRelations.doctors.length > 0"
        type="button"
        class="inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium backdrop-blur-md transition-all"
        :class="
          activeClusterKey === 'only_doctors'
            ? isDarkTheme
              ? 'border-white/80 bg-white text-black'
              : 'border-slate-900 bg-slate-900 text-white'
            : isDarkTheme
              ? 'border-white/10 bg-black/60 text-neutral-400 hover:border-white/25 hover:text-white'
              : 'border-slate-200 bg-white/85 text-slate-600 hover:border-slate-300 hover:text-slate-950'
        "
        @click="selectCluster('only_doctors')"
      >
        <span class="size-2 rounded-full bg-[#c4b5a6]" />
        <span>{{ UI_LABELS.doctorsChip(clinicRelations.doctors.length) }}</span>
      </button>

      <button
        v-if="clinicRelations.services.length > 0"
        type="button"
        class="inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium backdrop-blur-md transition-all"
        :class="
          activeClusterKey === 'only_services'
            ? isDarkTheme
              ? 'border-white/80 bg-white text-black'
              : 'border-slate-900 bg-slate-900 text-white'
            : isDarkTheme
              ? 'border-white/10 bg-black/60 text-neutral-400 hover:border-white/25 hover:text-white'
              : 'border-slate-200 bg-white/85 text-slate-600 hover:border-slate-300 hover:text-slate-950'
        "
        @click="selectCluster('only_services')"
      >
        <span class="size-2 rotate-45 bg-[#5d8a82]" />
        <span>{{
          UI_LABELS.servicesChip(clinicRelations.services.length)
        }}</span>
      </button>

      <button
        v-for="cluster in clusters"
        :key="cluster.key"
        type="button"
        class="inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium backdrop-blur-md transition-all"
        :class="
          activeClusterKey === cluster.key
            ? isDarkTheme
              ? 'border-white/80 bg-white text-black'
              : 'border-slate-900 bg-slate-900 text-white'
            : isDarkTheme
              ? 'border-white/10 bg-black/60 text-neutral-400 hover:border-white/25 hover:text-white'
              : 'border-slate-200 bg-white/85 text-slate-600 hover:border-slate-300 hover:text-slate-950'
        "
        data-testid="knowledge-cluster-chip"
        @click="selectCluster(cluster.key)"
      >
        <span>{{ cluster.label }}</span>
        <span class="opacity-60">{{ cluster.count }}</span>
      </button>
    </div>

    <!-- Top-Right Minimal Zoom & Reset Controls -->
    <div
      class="pointer-events-auto absolute right-4 top-4 z-10 flex items-center gap-1 rounded-xl border p-1 shadow-sm backdrop-blur-md"
      :class="
        isDarkTheme
          ? 'border-white/10 bg-black/60'
          : 'border-slate-200/90 bg-white/90'
      "
    >
      <Button
        icon="i-lucide-zoom-out"
        size="xs"
        variant="ghost"
        color="slate"
        :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ZOOM_OUT')"
        @click="zoomCamera(0.85)"
      />
      <Button
        icon="i-lucide-compass"
        size="xs"
        variant="ghost"
        color="slate"
        :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.RESET_3D_CAMERA')"
        @click="resetCamera"
      />
      <Button
        icon="i-lucide-zoom-in"
        size="xs"
        variant="ghost"
        color="slate"
        :title="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.ZOOM_IN')"
        @click="zoomCamera(1.18)"
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

    <!-- Bottom-Left Hermes Starmap Key Legend -->
    <div
      class="pointer-events-none absolute bottom-3 left-4 z-10 flex flex-col gap-1 text-[10px]"
      :class="isDarkTheme ? 'text-neutral-400' : 'text-slate-500'"
    >
      <span class="flex items-center gap-1.5">
        <span class="inline-block size-2 rounded-full bg-[#c4b5a6]" />
        <span>{{ UI_LABELS.legendSkill }}</span>
      </span>
      <span class="flex items-center gap-1.5">
        <span class="inline-block size-2 rotate-45 bg-[#5d8a82]" />
        <span>{{ UI_LABELS.legendMemory }}</span>
      </span>
      <span class="text-[9.5px] opacity-65">
        {{ UI_LABELS.legendSub }}
      </span>
    </div>

    <!-- Compact Inspector Card (shown when a node is selected; also keeps text in DOM for screen readers/specs) -->
    <div
      v-if="selectedNode"
      :class="[
        inspectorOpen
          ? 'pointer-events-auto absolute bottom-4 right-4 z-20 flex max-h-[calc(100%-5rem)] w-80 flex-col gap-3 overflow-y-auto rounded-xl border p-4 shadow-2xl backdrop-blur-xl sm:w-96'
          : 'sr-only',
        isDarkTheme
          ? 'border-white/15 bg-[#111114]/95 text-neutral-100'
          : 'border-slate-200 bg-white/95 text-slate-900',
      ]"
    >
      <div class="flex items-center justify-between gap-2">
        <span
          class="inline-flex items-center gap-1.5 rounded-md px-2 py-0.5 font-mono text-[10px] uppercase tracking-wider"
          :class="
            isDarkTheme
              ? 'bg-white/10 text-neutral-300'
              : 'bg-slate-100 text-slate-700'
          "
        >
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
              v-if="selectedNode.raw.documentable.type === 'Captain::Document'"
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

      <h3 class="m-0 text-sm font-semibold leading-snug">
        {{ selectedNode.question }}
      </h3>

      <!-- Doctor Node: Linked Services List -->
      <div
        v-if="
          selectedNode.kind === 'doctor' && selectedNode.linkedServices?.length
        "
        class="flex flex-col gap-1.5"
      >
        <span
          class="text-[11px] font-medium uppercase tracking-wide text-n-slate-10"
        >
          {{
            UI_LABELS.linkedServicesHeader(selectedNode.linkedServices.length)
          }}
        </span>
        <div class="flex max-h-48 flex-col gap-1 overflow-y-auto pr-1">
          <button
            v-for="srv in selectedNode.linkedServices"
            :key="srv.serviceId"
            type="button"
            class="flex items-center justify-between gap-2 rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-1.5 text-left text-xs transition-colors hover:border-n-brand"
            @click="selectNode(srv.rawId)"
          >
            <span class="truncate font-medium text-n-slate-12">
              {{ srv.name }}
            </span>
            <span class="shrink-0 font-mono text-[11px] text-n-slate-10">
              <template v-if="srv.price">
                {{ formatPriceKzt(srv.price) }}
              </template>
              <template v-else-if="srv.receptionsCount">
                {{ UI_LABELS.receptionsCount(srv.receptionsCount) }}
              </template>
            </span>
          </button>
        </div>
      </div>

      <!-- Service Node: Linked Doctors List -->
      <div
        v-if="
          selectedNode.kind === 'service' && selectedNode.linkedDoctors?.length
        "
        class="flex flex-col gap-1.5"
      >
        <span
          class="text-[11px] font-medium uppercase tracking-wide text-n-slate-10"
        >
          {{ UI_LABELS.linkedDoctorsHeader(selectedNode.linkedDoctors.length) }}
        </span>
        <div class="flex flex-wrap gap-1.5">
          <button
            v-for="doc in selectedNode.linkedDoctors"
            :key="doc.resourceId"
            type="button"
            class="inline-flex items-center gap-1.5 rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-1 text-left text-xs text-n-slate-12 transition-colors hover:border-n-brand"
            @click="selectNode(doc.rawId)"
          >
            <span class="size-1.5 rounded-full bg-[#c4b5a6]" />
            <span>{{ doc.name }}</span>
          </button>
        </div>
      </div>

      <!-- Answer / Details Box -->
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
            class="size-1.5"
            :class="
              peer.starmapKind === 'memory'
                ? 'rotate-45 bg-[#5d8a82]'
                : 'rounded-full bg-[#c4b5a6]'
            "
          />
          <span>{{ peer.label }}</span>
        </button>
      </div>
    </div>
  </div>
</template>
