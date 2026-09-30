import { afterEach, describe, expect, it } from 'vitest';
import { effectScope, nextTick, ref, watchEffect } from 'vue';
import {
  clearAudioPlaybackState,
  setAudioPlaybackState,
  useAudioPlaybackState,
} from './audioPlaybackState';

const ATTACHMENT_ID = 'shared-recording';

describe('audioPlaybackState', () => {
  let scope;

  afterEach(() => {
    scope?.stop();
    scope = null;
    clearAudioPlaybackState(ATTACHMENT_ID, 'a');
    clearAudioPlaybackState(ATTACHMENT_ID, 'b');
  });

  it('does not let two publishers of one attachment re-trigger each other', async () => {
    // Mirrors two audio chips rendering the same attachment. Production Vue
    // has no recursion guard, so a ping-pong here would freeze the tab.
    const runs = { a: 0, b: 0 };
    const labels = { a: ref('00:00 / 00:30'), b: ref('00:00 / 00:30') };
    const playing = { a: ref(false), b: ref(false) };

    scope = effectScope();
    scope.run(() => {
      ['a', 'b'].forEach(owner => {
        watchEffect(() => {
          runs[owner] += 1;
          setAudioPlaybackState(
            ATTACHMENT_ID,
            {
              timeLabel: labels[owner].value,
              isPlaying: playing[owner].value,
            },
            owner
          );
        });
      });
    });

    await nextTick();
    expect(runs).toEqual({ a: 1, b: 1 });

    playing.a.value = true;
    labels.a.value = '00:01 / 00:30';
    await nextTick();

    expect(runs).toEqual({ a: 2, b: 1 });
    expect(useAudioPlaybackState(ATTACHMENT_ID).value).toEqual({
      timeLabel: '00:01 / 00:30',
      isPlaying: true,
    });
  });

  it('prefers the playing publisher and clears only the unmounted one', () => {
    setAudioPlaybackState(
      ATTACHMENT_ID,
      { timeLabel: '00:00 / 00:30', isPlaying: false },
      'a'
    );
    setAudioPlaybackState(
      ATTACHMENT_ID,
      { timeLabel: '00:07 / 00:30', isPlaying: true },
      'b'
    );

    const state = useAudioPlaybackState(ATTACHMENT_ID);
    expect(state.value.timeLabel).toBe('00:07 / 00:30');

    clearAudioPlaybackState(ATTACHMENT_ID, 'a');
    expect(state.value.isPlaying).toBe(true);

    clearAudioPlaybackState(ATTACHMENT_ID, 'b');
    expect(state.value).toEqual({ timeLabel: '', isPlaying: false });
  });
});
