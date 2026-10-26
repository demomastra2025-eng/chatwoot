<script setup>
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';
import {
  STAGE,
  STAGE_VIEW,
} from 'dashboard/composables/captain/suggestionStages';

// A soft blue-teal glow that tells «AI is working» without words. Drawn on a
// canvas, no dependencies. The stage only changes the pace and the weight of
// the colours (smoothly, the shape never jumps).
const props = defineProps({
  stage: { type: String, default: STAGE.ANALYZING },
});

// Drawn at this logical size; CSS shows it at 84 px (68 px on a phone).
const SIZE = 84;
const STATIC_PHASE = 1.7;

// Weights of the four glows per hue
const HUE_WEIGHTS = {
  blue: [1, 0.5, 0.55, 0.45],
  teal: [0.62, 1, 0.6, 0.5],
  sky: [0.58, 0.6, 1, 0.85],
  pale: [0.8, 0.55, 0.8, 1],
};

// Four glows drifting along their own orbits inside the circle
const BLOBS = [
  { rgb: '30,120,255', ax: 0.61, ay: 0.47, shift: 0, reach: 0.95 },
  { rgb: '0,200,170', ax: 0.43, ay: 0.67, shift: 2.1, reach: 0.85 },
  { rgb: '90,190,255', ax: 0.77, ay: 0.39, shift: 4, reach: 0.8 },
  { rgb: '170,225,255', ax: 0.53, ay: 0.71, shift: 1.2, reach: 0.7 },
];

const canvas = ref(null);

let ctx = null;
let mix = [...HUE_WEIGHTS.blue];
let tempo = 1;
let phase = STATIC_PHASE;
let lastTick = 0;
let frameId = 0;
let onScreen = true;
let reducedMotion = false;
let intersection = null;
let motionQuery = null;
let themeWatcher = null;

const targetOf = () => {
  const view = STAGE_VIEW[props.stage] || STAGE_VIEW[STAGE.ANALYZING];
  return { weights: HUE_WEIGHTS[view.hue], tempo: view.tempo };
};

const isDark = () => document.body.classList.contains('dark');

const paint = () => {
  if (!ctx) return;
  const dark = isDark();
  const center = SIZE / 2;
  const radius = SIZE * 0.38 * (1 + 0.018 * Math.sin(phase * 1.3));

  ctx.clearRect(0, 0, SIZE, SIZE);

  const halo = ctx.createRadialGradient(
    center,
    center,
    radius * 0.9,
    center,
    center,
    SIZE * 0.5
  );
  halo.addColorStop(0, dark ? 'rgba(70,150,255,.22)' : 'rgba(60,150,255,.10)');
  halo.addColorStop(1, 'rgba(60,150,255,0)');
  ctx.fillStyle = halo;
  ctx.fillRect(0, 0, SIZE, SIZE);

  ctx.save();
  ctx.beginPath();
  ctx.arc(center, center, radius, 0, Math.PI * 2);
  ctx.clip();
  ctx.fillStyle = dark ? '#0e1d3a' : '#e9f1fb';
  ctx.fillRect(0, 0, SIZE, SIZE);

  ctx.globalCompositeOperation = dark ? 'screen' : 'source-over';
  BLOBS.forEach((blob, index) => {
    const x = center + Math.cos(phase * blob.ax + blob.shift) * radius * 0.55;
    const y =
      center + Math.sin(phase * blob.ay + blob.shift * 1.3) * radius * 0.55;
    const glow = ctx.createRadialGradient(x, y, 0, x, y, radius * blob.reach);
    const weight = dark ? Math.min(1, mix[index] * 1.15) : mix[index];
    glow.addColorStop(0, `rgba(${blob.rgb},${weight})`);
    glow.addColorStop(0.6, `rgba(${blob.rgb},${weight * 0.35})`);
    glow.addColorStop(1, `rgba(${blob.rgb},0)`);
    ctx.fillStyle = glow;
    ctx.fillRect(0, 0, SIZE, SIZE);
  });
  ctx.globalCompositeOperation = 'source-over';

  const sheen = ctx.createLinearGradient(
    0,
    center - radius,
    0,
    center + radius
  );
  sheen.addColorStop(
    0,
    dark ? 'rgba(255,255,255,.22)' : 'rgba(255,255,255,.34)'
  );
  sheen.addColorStop(0.5, 'rgba(255,255,255,0)');
  sheen.addColorStop(1, dark ? 'rgba(0,10,30,.12)' : 'rgba(10,40,110,.16)');
  ctx.fillStyle = sheen;
  ctx.fillRect(0, 0, SIZE, SIZE);
  ctx.restore();

  if (dark) {
    ctx.strokeStyle = 'rgba(160,200,255,.26)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(center, center, radius - 0.5, 0, Math.PI * 2);
    ctx.stroke();
  }
};

const snapToStage = () => {
  const target = targetOf();
  mix = [...target.weights];
  tempo = target.tempo;
};

const ease = deltaSeconds => {
  const target = targetOf();
  const k = 1 - Math.exp(-deltaSeconds * 2.6);
  mix = mix.map((value, index) => value + (target.weights[index] - value) * k);
  tempo += (target.tempo - tempo) * k;
};

const canAnimate = () =>
  Boolean(ctx) && !reducedMotion && onScreen && !document.hidden;

const frame = now => {
  frameId = 0;
  if (!canAnimate()) return;
  const delta = Math.min(0.05, (now - lastTick) / 1000);
  lastTick = now;
  ease(delta);
  phase += delta * tempo;
  paint();
  frameId = requestAnimationFrame(frame);
};

const stopLoop = () => {
  if (frameId) cancelAnimationFrame(frameId);
  frameId = 0;
};

// Runs only while the orb can be seen: on screen, tab visible, motion allowed
const syncLoop = () => {
  if (!canAnimate()) {
    stopLoop();
    return;
  }
  if (frameId) return;
  lastTick = performance.now();
  frameId = requestAnimationFrame(frame);
};

const repaintStill = () => {
  if (reducedMotion) {
    snapToStage();
    phase = STATIC_PHASE;
    paint();
  }
};

const onMotionChange = () => {
  reducedMotion = Boolean(motionQuery?.matches);
  repaintStill();
  syncLoop();
};

const onVisibilityChange = () => syncLoop();

onMounted(() => {
  ctx = canvas.value?.getContext?.('2d') || null;
  if (!ctx) return;

  const ratio = Math.min(2, window.devicePixelRatio || 1);
  canvas.value.width = Math.round(SIZE * ratio);
  canvas.value.height = Math.round(SIZE * ratio);
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);

  motionQuery = window.matchMedia?.('(prefers-reduced-motion: reduce)') || null;
  reducedMotion = Boolean(motionQuery?.matches);
  motionQuery?.addEventListener?.('change', onMotionChange);

  if (typeof IntersectionObserver !== 'undefined') {
    intersection = new IntersectionObserver(
      ([entry]) => {
        onScreen = entry.isIntersecting;
        syncLoop();
      },
      { rootMargin: '80px' }
    );
    intersection.observe(canvas.value);
  }

  document.addEventListener('visibilitychange', onVisibilityChange);

  if (typeof MutationObserver !== 'undefined') {
    // A theme switch repaints a still orb; a moving one repaints every frame
    themeWatcher = new MutationObserver(() => {
      if (!frameId) paint();
    });
    themeWatcher.observe(document.body, {
      attributes: true,
      attributeFilter: ['class'],
    });
  }

  snapToStage();
  paint();
  syncLoop();
});

watch(
  () => props.stage,
  () => repaintStill()
);

onBeforeUnmount(() => {
  stopLoop();
  intersection?.disconnect();
  themeWatcher?.disconnect();
  motionQuery?.removeEventListener?.('change', onMotionChange);
  document.removeEventListener('visibilitychange', onVisibilityChange);
});
</script>

<template>
  <span class="ai-orb" aria-hidden="true" data-test="ai-orb">
    <canvas ref="canvas" class="ai-orb__canvas" />
  </span>
</template>

<style scoped>
.ai-orb {
  display: block;
  flex: none;
  width: 68px;
  height: 68px;
  animation: ai-orb-in 0.6s cubic-bezier(0.16, 1, 0.3, 1) both;
}

@media (min-width: 640px) {
  .ai-orb {
    width: 84px;
    height: 84px;
  }
}

.ai-orb__canvas {
  display: block;
  width: 100%;
  height: 100%;
  filter: drop-shadow(0 7px 12px rgb(30 110 255 / 0.2));
}

:global(.dark) .ai-orb__canvas {
  filter: drop-shadow(0 7px 12px rgb(20 90 230 / 0.38));
}

@keyframes ai-orb-in {
  from {
    opacity: 0;
    transform: scale(0.86);
  }
  to {
    opacity: 1;
    transform: none;
  }
}

@media (prefers-reduced-motion: reduce) {
  .ai-orb {
    animation: none;
  }
}
</style>
