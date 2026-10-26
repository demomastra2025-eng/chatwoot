<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import AiOrb from './AiOrb.vue';
import { useStageDwell } from 'dashboard/composables/captain/useStageDwell';
import {
  SLOW_HINT_TEXT_KEY,
  STAGE,
  STAGE_VIEW,
} from 'dashboard/composables/captain/suggestionStages';

// What the manager sees while «Предложить ответ» works: the glow and one plain
// sentence about the step. It lives exactly as long as the run is shown, so
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
</script>

<template>
  <div
    class="mb-2 flex min-h-[7.5rem] w-full items-center gap-3.5 px-1 py-3 sm:gap-[18px] sm:px-2"
    :data-stage="stage"
    data-test="copilot-live-progress"
  >
    <AiOrb :stage="stage" />
    <div
      class="min-w-0 flex-1"
      role="status"
      aria-live="polite"
      data-test="copilot-stage"
    >
      <Transition name="ai-stage" mode="out-in">
        <p
          :key="stage"
          class="mb-0 text-base font-medium leading-snug text-n-slate-12 text-balance"
        >
          {{ stageText }}
        </p>
      </Transition>
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
.ai-stage-enter-active {
  transition:
    opacity 0.32s cubic-bezier(0.16, 1, 0.3, 1),
    transform 0.32s cubic-bezier(0.16, 1, 0.3, 1);
}

.ai-stage-leave-active {
  transition:
    opacity 0.14s ease-in,
    transform 0.14s ease-in;
}

.ai-stage-enter-from {
  opacity: 0;
  transform: translateY(5px);
}

.ai-stage-leave-to {
  opacity: 0;
  transform: translateY(-4px);
}

.ai-slow-enter-active {
  transition: opacity 0.6s ease-out;
}

.ai-slow-enter-from {
  opacity: 0;
}

@media (prefers-reduced-motion: reduce) {
  .ai-stage-enter-active,
  .ai-stage-leave-active,
  .ai-slow-enter-active {
    transition: none;
  }
}
</style>
