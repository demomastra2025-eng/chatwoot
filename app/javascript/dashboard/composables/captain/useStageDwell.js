import { computed, onScopeDispose, ref, toValue, watch } from 'vue';
import {
  DRAFTING_IDLE_MS,
  MIN_STAGE_DWELL_MS,
  SLOW_HINT_AFTER_MS,
  STAGE,
  deriveStage,
} from './suggestionStages';

/**
 * The stage the manager sees while a reply suggestion works, paced so that it
 * reads calmly:
 * - a shown stage stays at least `minDwellMs`; when events come faster, only
 *   the newest waiting stage is kept (a queue of one);
 * - after the tools are done and no event arrives for `draftingIdleMs`, the
 *   model is writing the text: the stage becomes «drafting»;
 * - after `slowAfterMs` of work `isSlow` turns on (a second, calm line).
 * The result of the run never waits for the stages: the caller swaps the panel
 * for the text at once and this composable simply goes away with it.
 *
 * Call it inside a component (or an effect scope) that lives exactly as long
 * as the run is shown: the timers end with the scope.
 *
 * @param {Object} options
 * @param {Ref<Object|null>|Function} options.progress - the latest progress
 *   payload, replaced by a new object on every event
 * @param {Ref<boolean>|Function} [options.queued] - the run waits in the queue
 * @returns {{stage: Ref<string>, isSlow: Ref<boolean>}}
 */
export function useStageDwell({
  progress,
  queued = false,
  minDwellMs = MIN_STAGE_DWELL_MS,
  draftingIdleMs = DRAFTING_IDLE_MS,
  slowAfterMs = SLOW_HINT_AFTER_MS,
} = {}) {
  const derived = computed(() =>
    deriveStage(toValue(progress), { queued: toValue(queued) })
  );

  const stage = ref(derived.value.key);
  const isSlow = ref(false);

  let shownAt = Date.now();
  let waiting = null;
  let dwellTimer = null;
  let idleTimer = null;
  let slowTimer = null;
  // The run's age is counted from the elapsed time the server reports, so a
  // clock that is off cannot hide or show the hint early.
  let anchor = { at: Date.now(), elapsedMs: 0 };

  const show = key => {
    stage.value = key;
    shownAt = Date.now();
    waiting = null;
  };

  const flush = () => {
    dwellTimer = null;
    if (waiting && waiting !== stage.value) {
      show(waiting);
    } else {
      waiting = null;
    }
  };

  const request = key => {
    if (key === stage.value) {
      waiting = null;
      return;
    }
    const wait = minDwellMs - (Date.now() - shownAt);
    if (wait <= 0 && !dwellTimer) {
      show(key);
      return;
    }
    waiting = key;
    if (!dwellTimer) {
      dwellTimer = setTimeout(flush, Math.max(0, wait));
    }
  };

  const armIdle = () => {
    clearTimeout(idleTimer);
    idleTimer = null;
    if (!derived.value.afterTools) return;
    idleTimer = setTimeout(() => {
      idleTimer = null;
      request(STAGE.DRAFTING);
    }, draftingIdleMs);
  };

  const armSlow = () => {
    clearTimeout(slowTimer);
    slowTimer = null;
    const left = slowAfterMs - (anchor.elapsedMs + (Date.now() - anchor.at));
    if (left <= 0) {
      isSlow.value = true;
      return;
    }
    slowTimer = setTimeout(() => {
      slowTimer = null;
      isSlow.value = true;
    }, left);
  };

  watch(
    () => derived.value.key,
    key => request(key)
  );

  // Every event replaces the progress object: a new event restarts the quiet
  // period, and the elapsed time it carries corrects the age of the run.
  watch(
    [() => toValue(progress), () => derived.value.afterTools],
    () => armIdle(),
    { immediate: true }
  );

  watch(
    () => toValue(progress)?.elapsed_ms,
    elapsed => {
      const elapsedMs = Number(elapsed);
      if (!Number.isFinite(elapsedMs) || elapsedMs < 0) return;
      anchor = { at: Date.now(), elapsedMs };
      armSlow();
    },
    { immediate: true }
  );

  // No age reported yet: count from now
  if (!slowTimer && !isSlow.value) armSlow();

  onScopeDispose(() => {
    clearTimeout(dwellTimer);
    clearTimeout(idleTimer);
    clearTimeout(slowTimer);
  });

  return { stage, isSlow };
}
