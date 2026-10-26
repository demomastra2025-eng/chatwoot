import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { effectScope, nextTick, ref, watch } from 'vue';
import { useStageDwell } from '../captain/useStageDwell';
import {
  DRAFTING_IDLE_MS,
  MIN_STAGE_DWELL_MS,
  SLOW_HINT_AFTER_MS,
  STAGE,
} from '../captain/suggestionStages';

const step = (tool, event) => ({
  id: `${tool}:${event}:1:call-${tool}`,
  tool_name: tool,
  event,
  status: event === 'complete' ? 'finish' : event,
  tool_call_id: `call-${tool}`,
});

// Every event of the run is a new object, as the cable delivers it
const event = (phase, steps = [], extra = {}) => ({
  phase,
  status: 'running',
  captain_trace: { tool_steps: steps },
  ...extra,
});

const running = tool => event('tool_running', [step(tool, 'start')]);

// Lets the watchers see what just changed, then lets the time pass
const flush = async (ms = 0) => {
  await nextTick();
  if (ms) vi.advanceTimersByTime(ms);
  await nextTick();
};

describe('useStageDwell', () => {
  let scope;
  let progress;
  let queued;
  let api;

  const start = (initial = null, options = {}) => {
    progress = ref(initial);
    queued = ref(false);
    scope = effectScope();
    api = scope.run(() => useStageDwell({ progress, queued, ...options }));
    return api;
  };

  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    scope?.stop();
    scope = null;
    vi.useRealTimers();
  });

  it('shows the stage of the first event at once', () => {
    start(null);
    expect(api.stage.value).toBe(STAGE.ANALYZING);

    scope.stop();
    start(running('search_available_slots'));
    expect(api.stage.value).toBe(STAGE.SLOTS);
  });

  describe('the minimum time of a stage', () => {
    it('switches at once when the shown stage has been there long enough', async () => {
      start(null);
      await flush(MIN_STAGE_DWELL_MS);

      progress.value = running('faq_lookup');
      await flush();

      expect(api.stage.value).toBe(STAGE.KNOWLEDGE);
    });

    it('holds a fresh stage for 800 ms before the next one shows', async () => {
      start(null);
      await flush(MIN_STAGE_DWELL_MS);
      progress.value = running('faq_lookup');
      await flush();
      expect(api.stage.value).toBe(STAGE.KNOWLEDGE);

      await flush(100);
      progress.value = running('search_scheduling_services');
      await flush();

      expect(api.stage.value).toBe(STAGE.KNOWLEDGE);
      await flush(MIN_STAGE_DWELL_MS - 100 - 1);
      expect(api.stage.value).toBe(STAGE.KNOWLEDGE);
      await flush(1);
      expect(api.stage.value).toBe(STAGE.SERVICES);
    });

    it('keeps only the newest of the stages that arrive while one is held', async () => {
      start(null);
      // record every stage the manager would see
      const shown = [];
      scope.run(() =>
        watch(api.stage, value => shown.push(value), { flush: 'sync' })
      );
      await flush(MIN_STAGE_DWELL_MS);
      progress.value = running('faq_lookup');
      await flush(100);
      progress.value = running('search_scheduling_services');
      await flush(100);
      progress.value = running('search_available_slots');
      await flush(2 * MIN_STAGE_DWELL_MS);

      expect(shown).toEqual([STAGE.KNOWLEDGE, STAGE.SLOTS]);
      expect(api.stage.value).toBe(STAGE.SLOTS);
    });

    it('drops the waiting stage when the shown one comes back', async () => {
      start(null);
      await flush(MIN_STAGE_DWELL_MS);
      progress.value = running('faq_lookup');
      await flush();
      await flush(100);
      progress.value = running('search_available_slots');
      await flush();
      progress.value = running('faq_lookup');
      await flush();

      await flush(2 * MIN_STAGE_DWELL_MS);
      expect(api.stage.value).toBe(STAGE.KNOWLEDGE);
    });

    it('lets the queue stage hold for 800 ms as well', async () => {
      start(null);
      await flush(MIN_STAGE_DWELL_MS);
      queued.value = true;
      await flush();
      expect(api.stage.value).toBe(STAGE.QUEUED);

      queued.value = false;
      progress.value = event('thinking');
      await flush();
      expect(api.stage.value).toBe(STAGE.QUEUED);
      await flush(MIN_STAGE_DWELL_MS);
      expect(api.stage.value).toBe(STAGE.ANALYZING);
    });

    it('honours a custom minimum', async () => {
      start(null, { minDwellMs: 200 });
      await flush(200);
      progress.value = running('faq_lookup');
      await flush();

      expect(api.stage.value).toBe(STAGE.KNOWLEDGE);
    });
  });

  describe('«drafting»', () => {
    const lookupDone = () =>
      event('thinking', [
        step('search_available_slots', 'start'),
        step('search_available_slots', 'complete'),
      ]);

    it('comes after 2.5 s without events once the tools are done', async () => {
      start(null);
      await flush(MIN_STAGE_DWELL_MS);
      progress.value = lookupDone();
      await flush();
      expect(api.stage.value).toBe(STAGE.ANALYZING);

      await flush(DRAFTING_IDLE_MS - 1);
      expect(api.stage.value).toBe(STAGE.ANALYZING);
      await flush(1);
      expect(api.stage.value).toBe(STAGE.DRAFTING);
    });

    it('waits again when a new event arrives in the meantime', async () => {
      start(null);
      await flush(MIN_STAGE_DWELL_MS);
      progress.value = lookupDone();
      await flush(DRAFTING_IDLE_MS - 500);

      progress.value = lookupDone();
      await flush(DRAFTING_IDLE_MS - 1);
      expect(api.stage.value).not.toBe(STAGE.DRAFTING);
      await flush(1);
      expect(api.stage.value).toBe(STAGE.DRAFTING);
    });

    it('never comes when no tool ran', async () => {
      start(event('thinking'));
      await flush(10 * DRAFTING_IDLE_MS);

      expect(api.stage.value).toBe(STAGE.ANALYZING);
    });

    it('does not come while a tool is still running', async () => {
      start(running('search_available_slots'));
      await flush(10 * DRAFTING_IDLE_MS);

      expect(api.stage.value).toBe(STAGE.SLOTS);
    });

    it('shows at once after a booking tool is done', async () => {
      start(null);
      await flush(MIN_STAGE_DWELL_MS);
      progress.value = event('tool_running', [
        step('create_appointment', 'start'),
        step('create_appointment', 'complete'),
      ]);
      await flush();

      expect(api.stage.value).toBe(STAGE.DRAFTING);
    });

    it('gives way to a tool that starts after it', async () => {
      start(null);
      await flush(MIN_STAGE_DWELL_MS);
      progress.value = lookupDone();
      await flush(DRAFTING_IDLE_MS);
      expect(api.stage.value).toBe(STAGE.DRAFTING);

      progress.value = running('faq_lookup');
      await flush(MIN_STAGE_DWELL_MS);

      expect(api.stage.value).toBe(STAGE.KNOWLEDGE);
    });

    it('honours a custom quiet period', async () => {
      start(null, { draftingIdleMs: 300 });
      await flush(MIN_STAGE_DWELL_MS);
      progress.value = lookupDone();
      await flush(300);

      expect(api.stage.value).toBe(STAGE.DRAFTING);
    });
  });

  describe('the hint about a long wait', () => {
    it('is off at first and comes after 30 s', async () => {
      start(null);
      expect(api.isSlow.value).toBe(false);

      await flush(SLOW_HINT_AFTER_MS - 1);
      expect(api.isSlow.value).toBe(false);
      await flush(1);
      expect(api.isSlow.value).toBe(true);
    });

    it('counts from the elapsed time the server reports', async () => {
      start(null);
      progress.value = event('thinking', [], { elapsed_ms: 25000 });
      await flush();

      await flush(5000 - 1);
      expect(api.isSlow.value).toBe(false);
      await flush(1);
      expect(api.isSlow.value).toBe(true);
    });

    it('is on at once for a run that is already long when the panel opens', () => {
      start(event('thinking', [], { elapsed_ms: 41000 }));

      expect(api.isSlow.value).toBe(true);
    });

    it('counts the age the server reports, never a timestamp compared with the page clock', async () => {
      start(null);
      progress.value = event('thinking', [], {
        started_at: '2000-01-01T00:00:00.000Z',
        elapsed_ms: 2000,
      });
      await flush();

      expect(api.isSlow.value).toBe(false);
      await flush(SLOW_HINT_AFTER_MS - 2000 - 1);
      expect(api.isSlow.value).toBe(false);
      await flush(1);
      expect(api.isSlow.value).toBe(true);
    });

    it('ignores a missing or broken elapsed time', async () => {
      start(null);
      progress.value = event('thinking', [], { elapsed_ms: 'soon' });
      await flush();
      progress.value = event('thinking', [], { elapsed_ms: -5 });
      await flush();

      expect(api.isSlow.value).toBe(false);
      await flush(SLOW_HINT_AFTER_MS);
      expect(api.isSlow.value).toBe(true);
    });
  });

  it('stops every timer when the scope ends', async () => {
    start(null);
    await flush(MIN_STAGE_DWELL_MS);
    progress.value = running('faq_lookup');
    await flush(100);
    progress.value = running('search_available_slots');
    await flush();

    scope.stop();
    await flush(10 * SLOW_HINT_AFTER_MS);

    expect(api.stage.value).toBe(STAGE.KNOWLEDGE);
    expect(api.isSlow.value).toBe(false);
    expect(vi.getTimerCount()).toBe(0);
  });
});
