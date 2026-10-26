<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import AiOrb from './AiOrb.vue';
import { useStageDwell } from 'dashboard/composables/captain/useStageDwell';
import {
  SLOW_HINT_TEXT_KEY,
  STAGE,
  STAGE_VIEW,
} from 'dashboard/composables/captain/suggestionStages';

// What the manager sees while «Предложить ответ» works: the dots orb and one
// plain sentence about the step. It lives exactly as long as the run is shown, so
// its timers end when the text arrives.
const props = defineProps({
  progress: { type: Object, default: null },
  queued: { type: Boolean, default: false },
});

const { t } = useI18n();

const { stage, isSlow } = useStageDwell({
  progress: () => props.progress,
  queued: () => props.queued,
});

const stageText = computed(() =>
  t((STAGE_VIEW[stage.value] || STAGE_VIEW[STAGE.ANALYZING]).text)
);

// Every new sentence is revealed again from the left. The class is taken off,
// the layout is read so that the browser registers the change, and the class
// is put back; the shimmer and the reveal themselves are plain CSS.
const sentence = ref(null);
const replayReveal = () => {
  const el = sentence.value;
  if (!el) return;
  el.classList.remove('ai-text--enter');
  el.getBoundingClientRect();
  el.classList.add('ai-text--enter');
};
watch(stageText, replayReveal, { flush: 'post' });
</script>

<template>
  <div
    class="mb-2 flex min-h-[7.5rem] w-full items-center gap-3.5 px-1 py-3 sm:gap-[18px] sm:px-2"
    :data-stage="stage"
    data-test="copilot-live-progress"
  >
    <AiOrb />
    <div
      class="min-w-0 flex-1"
      role="status"
      aria-live="polite"
      data-test="copilot-stage"
    >
      <p
        ref="sentence"
        class="ai-text ai-text--enter mb-0 text-base font-medium leading-snug text-balance"
        data-test="copilot-stage-text"
      >
        {{ stageText }}
      </p>
      <Transition name="ai-slow">
        <p
          v-if="isSlow"
          class="mb-0 mt-1 text-sm leading-snug text-n-slate-11"
          data-test="copilot-slow-hint"
        >
          {{ t(SLOW_HINT_TEXT_KEY) }}
        </p>
      </Transition>
    </div>
  </div>
</template>

<style scoped>
/* The sentence: a blue highlight runs along it all the time, and a new
   sentence is revealed from the left out of a soft blur. Colours come from the
   theme tokens, so both themes stay readable; the text itself stays the
   plain sentence for assistive technology. */
.ai-text {
  --ai-text-base: var(--slate-11);
  --ai-text-edge: var(--blue-11);
  --ai-text-peak: var(--blue-9);

  background: linear-gradient(
    100deg,
    rgb(var(--ai-text-base)) 0%,
    rgb(var(--ai-text-base)) 38%,
    rgb(var(--ai-text-edge)) 46%,
    rgb(var(--ai-text-peak)) 50%,
    rgb(var(--ai-text-edge)) 54%,
    rgb(var(--ai-text-base)) 62%,
    rgb(var(--ai-text-base)) 100%
  );
  background-size: 250% 100%;
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
  -webkit-text-fill-color: transparent;
  animation: ai-shimmer 2.4s linear infinite;
}

:global(.dark) .ai-text {
  --ai-text-peak: var(--blue-11);
}

.ai-text--enter {
  -webkit-mask-image: linear-gradient(90deg, #000 0 40%, transparent 60% 100%);
  mask-image: linear-gradient(90deg, #000 0 40%, transparent 60% 100%);
  -webkit-mask-size: 300% 100%;
  mask-size: 300% 100%;
  -webkit-mask-repeat: no-repeat;
  mask-repeat: no-repeat;
  animation:
    ai-shimmer 2.4s linear infinite,
    ai-reveal 0.75s cubic-bezier(0.16, 1, 0.3, 1) both;
}

@keyframes ai-shimmer {
  from {
    background-position: 100% 0;
  }
  to {
    background-position: -150% 0;
  }
}

@keyframes ai-reveal {
  from {
    -webkit-mask-position: 100% 0;
    mask-position: 100% 0;
    filter: blur(3px);
  }
  to {
    -webkit-mask-position: 0 0;
    mask-position: 0 0;
    filter: blur(0);
  }
}

/* «Reduce motion»: slower, never still */
@media (prefers-reduced-motion: reduce) {
  .ai-text {
    animation-duration: 4.8s;
  }

  .ai-text--enter {
    animation-duration: 4.8s, 1.2s;
  }
}

/* High contrast: the system colours, no gradient text */
@media (forced-colors: active) {
  .ai-text {
    background: none;
    -webkit-text-fill-color: currentcolor;
    color: CanvasText;
    animation: none;
  }

  .ai-text--enter {
    -webkit-mask-image: none;
    mask-image: none;
    animation: none;
  }
}

.ai-slow-enter-active {
  transition: opacity 0.6s ease-out;
}

.ai-slow-enter-from {
  opacity: 0;
}

@media (prefers-reduced-motion: reduce) {
  .ai-slow-enter-active {
    transition: none;
  }
}
</style>
