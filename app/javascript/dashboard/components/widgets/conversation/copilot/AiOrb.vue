<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue';
import {
  MODE_FRAMES,
  paintFrame,
  resolvePreset,
} from './vendor/thinkingOrbsEngine';

// A turning globe of dots that tells «AI is working» without words. The dots
// are computed and painted by the thinking-orbs engine (vendored, MIT). It is
// the same globe at the same pace for every stage: the sentence next to it
// says what the step is.
const STATE = 'searching';
// The engine draws on a grid of 64 units; the canvas scales it to its size.
const GRID = 64;
// Drawn at this logical size; CSS shows it at 84 px (68 px on a phone).
const SIZE = 84;
const START_PHASE = 1.7;
// «Reduce motion» in the system: the globe does not freeze, it turns at half
// speed.
const REDUCED_PACE = 0.5;
// The product blue, when the theme colour cannot be read
const FALLBACK_TINT = { r: 8, g: 109, b: 224 };

const canvas = ref(null);

let ctx = null;
let ratio = 1;
let preset = null;
let theme = { dark: false, tint: FALLBACK_TINT };
let phase = START_PHASE;
let pace = 1;
let lastTick = 0;
let frameId = 0;
let onScreen = true;
let intersection = null;
let motionQuery = null;
let themeWatcher = null;

// Dark mode is a class on the page; --blue-11 holds the product blue of the
// current theme as «r g b»
const readTheme = () => {
  const parts = getComputedStyle(document.body)
    .getPropertyValue('--blue-11')
    .trim()
    .split(/\s+/)
    .map(Number);
  const [r, g, b] = parts;
  const known = parts.length === 3 && parts.every(Number.isFinite);
  return {
    dark: document.body.classList.contains('dark'),
    tint: known ? { r, g, b } : FALLBACK_TINT,
  };
};

const paint = () => {
  if (!ctx || !preset) return;
  const scale = SIZE / GRID;
  ctx.setTransform(ratio * scale, 0, 0, ratio * scale, 0, 0);
  ctx.clearRect(0, 0, GRID, GRID);
  const frame = MODE_FRAMES[preset.mode](
    GRID,
    phase * preset.speed,
    preset.opts
  );
  paintFrame(ctx, frame, theme.dark, theme.tint);
};

const canAnimate = () => Boolean(ctx) && onScreen && !document.hidden;

const frame = now => {
  frameId = 0;
  if (!canAnimate()) return;
  const delta = Math.min(0.05, (now - lastTick) / 1000);
  lastTick = now;
  phase += delta * pace;
  paint();
  frameId = requestAnimationFrame(frame);
};

const stopLoop = () => {
  if (frameId) cancelAnimationFrame(frameId);
  frameId = 0;
};

// Runs only while the orb can be seen: on screen and the tab visible. The
// motion preference only sets the pace, it never stops the globe.
const syncLoop = () => {
  if (!canAnimate()) {
    stopLoop();
    return;
  }
  if (frameId) return;
  lastTick = performance.now();
  frameId = requestAnimationFrame(frame);
};

const onMotionChange = () => {
  pace = motionQuery?.matches ? REDUCED_PACE : 1;
};

const onVisibilityChange = () => syncLoop();

onMounted(() => {
  ctx = canvas.value?.getContext?.('2d') || null;
  if (!ctx) return;

  preset = resolvePreset(STATE, GRID);
  ratio = Math.min(2, window.devicePixelRatio || 1);
  canvas.value.width = Math.round(SIZE * ratio);
  canvas.value.height = Math.round(SIZE * ratio);

  motionQuery = window.matchMedia?.('(prefers-reduced-motion: reduce)') || null;
  onMotionChange();
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

  theme = readTheme();
  if (typeof MutationObserver !== 'undefined') {
    // A theme switch repaints a paused orb; a moving one repaints every frame
    themeWatcher = new MutationObserver(() => {
      theme = readTheme();
      if (!frameId) paint();
    });
    themeWatcher.observe(document.body, {
      attributes: true,
      attributeFilter: ['class'],
    });
  }

  paint();
  syncLoop();
});

onBeforeUnmount(() => {
  stopLoop();
  ctx = null;
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
</style>
