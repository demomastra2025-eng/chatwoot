import { mount, flushPromises } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const waveSurferState = vi.hoisted(() => ({ instances: [] }));

vi.mock('wavesurfer.js', async () => {
  const { markRaw } = await import('vue');
  return {
    default: {
      create: vi.fn(() => {
        const handlers = {};
        const instance = {
          handlers,
          on: vi.fn((event, handler) => {
            handlers[event] = handler;
          }),
          // Downloading + decoding the whole recording has not finished yet.
          load: vi.fn(() => new Promise(() => {})),
          destroy: vi.fn(),
          setMuted: vi.fn(),
          getMuted: vi.fn(() => false),
          setPlaybackRate: vi.fn(),
          getDuration: vi.fn(() => 32.5),
          getCurrentTime: vi.fn(() => 0),
          playPause: vi.fn(() => Promise.resolve()),
          pause: vi.fn(),
        };
        waveSurferState.instances.push(instance);
        // Keep the fake player out of Vue's reactivity, like a real instance
        // whose internals Vue never needs to track.
        return markRaw(instance);
      }),
    },
  };
});

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useAttachmentAvailability', async () => {
  const { ref } = await import('vue');
  return {
    useAttachmentAvailability: () => ({
      isPurged: ref(false),
      refreshAfterMediaFailure: vi.fn(),
    }),
  };
});
vi.mock('@chatwoot/utils', () => ({ downloadFile: vi.fn() }));

import AudioChip from './Audio.vue';
import { downloadFile } from '@chatwoot/utils';
import { useAlert } from 'dashboard/composables';
import { useAudioPlaybackState } from '../audioPlaybackState';
import { emitter } from 'shared/helpers/mitt';

const RECORDING_URL =
  '/api/v1/accounts/77/telephony/calls/sipuni%3Alocal%3Aabc/recording?recording_token=signed';

let wrapper;

const mountChip = (attachmentOverrides = {}, props = {}) => {
  wrapper = mount(AudioChip, {
    props: {
      attachment: {
        id: 'voice-recordings/janus/77/call/recording.wav',
        fileType: 'audio',
        extension: 'wav',
        dataUrl: RECORDING_URL,
        ...attachmentOverrides,
      },
      ...props,
    },
    global: { stubs: { Icon: true } },
  });
  return wrapper;
};

const playButton = chipWrapper => chipWrapper.findAll('button')[0];
const transcriptToggle = chipWrapper =>
  chipWrapper.find('[data-testid="audio-transcript-toggle"]');
const transcriptBody = chipWrapper =>
  chipWrapper.find('[data-testid="audio-transcript"]');
// The transcript toggle is the last button in the chip, so the download action
// is the last button that is not the toggle.
const downloadButton = chipWrapper =>
  chipWrapper
    .findAll('button')
    .filter(
      button => button.attributes('data-testid') !== 'audio-transcript-toggle'
    )
    .at(-1);

describe('Audio chip playback', () => {
  let playSpy;
  let loadSpy;
  let widthSpy;

  beforeEach(() => {
    waveSurferState.instances.length = 0;
    playSpy = vi
      .spyOn(window.HTMLMediaElement.prototype, 'play')
      .mockResolvedValue(undefined);
    vi.spyOn(window.HTMLMediaElement.prototype, 'pause').mockImplementation(
      () => {}
    );
    loadSpy = vi
      .spyOn(window.HTMLMediaElement.prototype, 'load')
      .mockImplementation(() => {});
    vi.stubGlobal('requestAnimationFrame', cb => {
      queueMicrotask(() => cb(0));
      return 1;
    });
    vi.stubGlobal('cancelAnimationFrame', () => {});
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    widthSpy?.mockRestore();
    widthSpy = null;
  });

  const withContainerWidth = width => {
    widthSpy = vi
      .spyOn(window.HTMLElement.prototype, 'clientWidth', 'get')
      .mockReturnValue(width);
  };

  it('does not restart native playback after another chip cancels pending waveform play', async () => {
    withContainerWidth(300);
    const chip = mountChip();
    await flushPromises();
    const [waveSurfer] = waveSurferState.instances;
    waveSurfer.handlers.ready(30);
    let rejectPlay;
    waveSurfer.playPause.mockReturnValueOnce(
      new Promise((resolve, reject) => {
        rejectPlay = reject;
      })
    );
    await playButton(chip).trigger('click');
    await flushPromises();

    emitter.emit('pause_playing_audio', -999);
    rejectPlay(new DOMException('interrupted', 'AbortError'));
    await flushPromises();

    expect(playSpy).not.toHaveBeenCalled();
    expect(useAlert).not.toHaveBeenCalled();
  });

  it.each(['native', 'waveform'])(
    'does not report or restart a pending %s play after user pause',
    async player => {
      withContainerWidth(player === 'native' ? 0 : 300);
      const chip = mountChip();
      await flushPromises();
      let rejectPlay;
      const pendingPlay = new Promise((resolve, reject) => {
        rejectPlay = reject;
      });
      if (player === 'native') {
        playSpy.mockReturnValueOnce(pendingPlay);
      } else {
        const [waveSurfer] = waveSurferState.instances;
        waveSurfer.handlers.ready(30);
        waveSurfer.playPause.mockReturnValueOnce(pendingPlay);
      }
      await playButton(chip).trigger('click');
      await flushPromises();
      if (player === 'native') {
        await chip.find('audio').trigger('loadedmetadata');
        await chip.find('audio').trigger('play');
        Object.defineProperty(chip.find('audio').element, 'paused', {
          configurable: true,
          value: false,
        });
      } else {
        waveSurferState.instances[0].handlers.play();
      }

      await playButton(chip).trigger('click');
      rejectPlay(new DOMException('interrupted by pause', 'AbortError'));
      await flushPromises();

      expect(useAlert).not.toHaveBeenCalled();
      expect(playSpy).toHaveBeenCalledTimes(player === 'native' ? 1 : 0);
    }
  );

  it('allows a new play after another chip cancels fallback source loading', async () => {
    withContainerWidth(0);
    const chip = mountChip();
    const click = playButton(chip).trigger('click');
    emitter.emit('pause_playing_audio', -999);
    await click;
    await flushPromises();
    expect(playSpy).not.toHaveBeenCalled();

    await playButton(chip).trigger('click');
    await flushPromises();
    expect(chip.find('audio').attributes('src')).toContain(
      'recording_token=signed'
    );
    expect(playSpy).toHaveBeenCalledTimes(1);
    expect(useAlert).not.toHaveBeenCalled();
  });

  it.each([NaN, Infinity])(
    'updates late native duration after metadata reported %s',
    async initialDuration => {
      withContainerWidth(0);
      const chip = mountChip();
      await playButton(chip).trigger('click');
      await flushPromises();

      const audio = chip.find('audio').element;
      let nativeDuration = initialDuration;
      Object.defineProperty(audio, 'duration', {
        configurable: true,
        get: () => nativeDuration,
      });
      await chip.find('audio').trigger('loadedmetadata');
      const state = useAudioPlaybackState(chip.props('attachment').id);
      expect(state.value.timeLabel).toBe('00:00 / 00:00');

      nativeDuration = 20.76;
      await chip.find('audio').trigger('durationchange');
      expect(state.value.timeLabel).toBe('00:00 / 00:20');
      nativeDuration = Infinity;
      await chip.find('audio').trigger('durationchange');
      expect(state.value.timeLabel).toBe('00:00 / 00:20');
    }
  );

  it.each(['NotSupportedError', 'AbortError'])(
    'explains a current native %s without exposing its message',
    async errorName => {
      withContainerWidth(0);
      playSpy.mockRejectedValueOnce(
        new DOMException('private media URL', errorName)
      );
      const chip = mountChip();
      await playButton(chip).trigger('click');
      await flushPromises();

      expect(useAlert).toHaveBeenCalledExactlyOnceWith(
        'CONVERSATION.REPLYBOX.TIP_AUDIORECORDER_ERROR'
      );
    }
  );

  it('plays the native fallback on the same click when waveform play rejects', async () => {
    withContainerWidth(300);
    const chip = mountChip();
    await flushPromises();
    const [waveSurfer] = waveSurferState.instances;
    waveSurfer.handlers.ready(32.5);
    waveSurfer.playPause.mockRejectedValueOnce(new Error('waveform failed'));
    await playButton(chip).trigger('click');
    await flushPromises();

    expect(waveSurfer.destroy).toHaveBeenCalledTimes(1);
    expect(playSpy).toHaveBeenCalledTimes(1);
    expect(chip.find('audio').attributes('src')).toContain(
      'recording_token=signed'
    );
  });

  it.each([
    ['native', 'URL change'],
    ['native', 'unmount'],
    ['waveform', 'URL change'],
    ['waveform', 'unmount'],
  ])('ignores a stale %s play rejection after %s', async (player, change) => {
    withContainerWidth(player === 'native' ? 0 : 300);
    const chip = mountChip();
    await flushPromises();
    let rejectPlay;
    const pendingPlay = new Promise((resolve, reject) => {
      rejectPlay = reject;
    });
    if (player === 'native') {
      playSpy.mockReturnValueOnce(pendingPlay);
    } else {
      const [waveSurfer] = waveSurferState.instances;
      waveSurfer.handlers.ready(32.5);
      waveSurfer.playPause.mockReturnValueOnce(pendingPlay);
    }
    await playButton(chip).trigger('click');
    await flushPromises();

    if (change === 'URL change') {
      await chip.setProps({
        attachment: {
          ...chip.props('attachment'),
          dataUrl: '/synthetic/replacement.ogg',
        },
      });
    } else {
      chip.unmount();
      wrapper = null;
    }
    rejectPlay(new DOMException('old source aborted', 'AbortError'));
    await flushPromises();

    expect(useAlert).not.toHaveBeenCalled();
    expect(playSpy).toHaveBeenCalledTimes(player === 'native' ? 1 : 0);
  });

  it('plays through the native audio element when the chip was mounted hidden', async () => {
    withContainerWidth(0);
    const chip = mountChip();
    await flushPromises();

    expect(waveSurferState.instances).toHaveLength(0);

    await playButton(chip).trigger('click');
    await flushPromises();

    const audio = chip.find('audio').element;
    expect(audio.getAttribute('src')).toContain('recording_token=signed');
    expect(audio.getAttribute('src')).toContain('t=');
    expect(playSpy).toHaveBeenCalledTimes(1);
  });

  it('does not ignore play while the waveform is still downloading', async () => {
    withContainerWidth(300);
    const chip = mountChip();
    await flushPromises();

    expect(waveSurferState.instances).toHaveLength(1);
    const [waveSurfer] = waveSurferState.instances;
    expect(waveSurfer.load).toHaveBeenCalledWith(
      expect.stringContaining('recording_token=signed')
    );

    await playButton(chip).trigger('click');
    await flushPromises();

    expect(waveSurfer.destroy).toHaveBeenCalled();
    expect(waveSurfer.playPause).not.toHaveBeenCalled();
    expect(playSpy).toHaveBeenCalledTimes(1);
    expect(chip.find('audio').element.getAttribute('src')).toContain(
      'recording_token=signed'
    );
  });

  it('reloads the native source on the next play after it failed', async () => {
    withContainerWidth(0);
    const chip = mountChip();
    await flushPromises();

    await playButton(chip).trigger('click');
    await flushPromises();

    const audio = chip.find('audio').element;
    expect(loadSpy).toHaveBeenCalledTimes(1);
    expect(playSpy).toHaveBeenCalledTimes(1);

    // Transient network error or an expired signed URL.
    audio.removeAttribute('src');
    audio.dispatchEvent(new Event('error'));
    await flushPromises();

    await playButton(chip).trigger('click');
    await flushPromises();

    expect(loadSpy).toHaveBeenCalledTimes(2);
    expect(audio.getAttribute('src')).toContain('recording_token=signed');
    expect(playSpy).toHaveBeenCalledTimes(2);

    // A healthy source is not reloaded on every play.
    await playButton(chip).trigger('click');
    await flushPromises();

    expect(loadSpy).toHaveBeenCalledTimes(2);
    expect(playSpy).toHaveBeenCalledTimes(3);
  });

  it('keeps using the waveform player once it is ready', async () => {
    withContainerWidth(300);
    const chip = mountChip();
    await flushPromises();

    const [waveSurfer] = waveSurferState.instances;
    waveSurfer.handlers.ready(32.5);
    await flushPromises();

    expect(chip.find('input[type="range"]').element.disabled).toBe(false);

    await playButton(chip).trigger('click');
    await flushPromises();

    expect(waveSurfer.playPause).toHaveBeenCalledTimes(1);
    expect(waveSurfer.destroy).not.toHaveBeenCalled();
    expect(playSpy).not.toHaveBeenCalled();
  });

  it('renders fallback equalizer waveform when in native fallback mode', async () => {
    withContainerWidth(0);
    const chip = mountChip();
    await flushPromises();

    expect(chip.find('[data-testid="audio-fallback-waveform"]').exists()).toBe(
      true
    );

    await playButton(chip).trigger('click');
    await flushPromises();

    expect(chip.find('[data-testid="audio-fallback-waveform"]').exists()).toBe(
      true
    );
  });

  it('cycles playback speeds including 1.25x and does not render +/-10s seek buttons', async () => {
    withContainerWidth(300);
    const chip = mountChip();
    await flushPromises();

    const [waveSurfer] = waveSurferState.instances;
    waveSurfer.handlers.ready(30);
    await flushPromises();

    // Start playing
    await playButton(chip).trigger('click');
    waveSurfer.handlers.play?.();
    await flushPromises();

    // Speed button is shown while playing
    const speedButton = chip
      .findAll('button')
      .find(btn => btn.text().includes('x'));
    expect(speedButton.text()).toBe('1x');

    await speedButton.trigger('click');
    expect(waveSurfer.setPlaybackRate).toHaveBeenCalledWith(1.25);
    expect(speedButton.text()).toBe('1.25x');

    await speedButton.trigger('click');
    expect(waveSurfer.setPlaybackRate).toHaveBeenCalledWith(1.5);
    expect(speedButton.text()).toBe('1.5x');

    await speedButton.trigger('click');
    expect(waveSurfer.setPlaybackRate).toHaveBeenCalledWith(2);
    expect(speedButton.text()).toBe('2x');

    await speedButton.trigger('click');
    expect(waveSurfer.setPlaybackRate).toHaveBeenCalledWith(1);
    expect(speedButton.text()).toBe('1x');

    // +/-10s seek buttons are not rendered
    const seekForwardBtn = chip
      .findAll('button')
      .find(btn => btn.text() === '+10s');
    const seekBackwardBtn = chip
      .findAll('button')
      .find(btn => btn.text() === '-10s');
    expect(seekForwardBtn).toBeUndefined();
    expect(seekBackwardBtn).toBeUndefined();
  });
  it('uses native playback when Safari cannot decode an MP3 waveform', async () => {
    withContainerWidth(300);
    const chip = mountChip({
      id: 'voice-recordings/janus/77/call/recording.mp3',
      extension: 'mp3',
      dataUrl:
        '/api/v1/accounts/77/telephony/calls/sipuni%3Alocal%3Aabc/recording.mp3?recording_token=signed',
    });
    await flushPromises();

    const [waveSurfer] = waveSurferState.instances;
    await waveSurfer.handlers.error(new Error('Web Audio MP3 decode failed'));
    await flushPromises();

    const audio = chip.find('audio').element;
    expect(chip.find('[data-testid="audio-fallback-waveform"]').exists()).toBe(
      true
    );
    expect(audio.getAttribute('src')).toContain('.mp3');
    expect(audio.getAttribute('src')).toContain('recording_token=signed');

    await playButton(chip).trigger('click');
    await flushPromises();

    expect(playSpy).toHaveBeenCalledTimes(1);
  });

  it('keeps transcript text and the recording download action in fallback mode', async () => {
    withContainerWidth(0);
    const chip = mountChip({
      transcribedText: 'The caller asked for a callback.',
    });
    await flushPromises();

    await transcriptToggle(chip).trigger('click');
    expect(chip.text()).toContain('The caller asked for a callback.');

    await downloadButton(chip).trigger('click');
    await flushPromises();

    expect(downloadFile).toHaveBeenCalledWith({
      url: expect.stringContaining('recording_token=signed'),
      type: 'audio',
      extension: 'wav',
    });
  });

  it('uses the current attachment after the prop object is replaced', async () => {
    withContainerWidth(0);
    const chip = mountChip({ transcribedText: 'Previous transcript' });
    await flushPromises();
    await transcriptToggle(chip).trigger('click');
    expect(chip.text()).toContain('Previous transcript');

    const replacementUrl =
      '/api/v1/accounts/77/telephony/calls/recording?recording_token=refreshed';
    await chip.setProps({
      attachment: {
        ...chip.props('attachment'),
        id: 'voice-recordings/janus/77/call/refreshed.wav',
        dataUrl: replacementUrl,
        transcribedText: 'Updated transcript',
      },
    });
    await flushPromises();

    expect(chip.text()).toContain('Updated transcript');
    expect(chip.text()).not.toContain('Previous transcript');

    await downloadButton(chip).trigger('click');
    await flushPromises();

    expect(downloadFile).toHaveBeenCalledWith(
      expect.objectContaining({ url: expect.stringContaining('refreshed') })
    );
  });

  describe('transcript', () => {
    const TRANSCRIPT = 'The caller asked for a callback.';

    it('is collapsed by default and only offers a toggle', async () => {
      withContainerWidth(0);
      const chip = mountChip({ transcribedText: TRANSCRIPT });
      await flushPromises();

      const toggle = transcriptToggle(chip);
      expect(toggle.exists()).toBe(true);
      expect(toggle.text()).toBe('CONVERSATION.SHOW_TRANSCRIPT');
      expect(toggle.attributes('aria-expanded')).toBe('false');
      expect(transcriptBody(chip).exists()).toBe(false);
      expect(chip.text()).not.toContain(TRANSCRIPT);
    });

    it('shows the transcript after the toggle is clicked and hides it again', async () => {
      withContainerWidth(0);
      const chip = mountChip({ transcribedText: TRANSCRIPT });
      await flushPromises();

      await transcriptToggle(chip).trigger('click');

      expect(transcriptBody(chip).text()).toBe(TRANSCRIPT);
      expect(transcriptToggle(chip).text()).toBe(
        'CONVERSATION.HIDE_TRANSCRIPT'
      );
      expect(transcriptToggle(chip).attributes('aria-expanded')).toBe('true');
      expect(transcriptToggle(chip).attributes('aria-controls')).toBe(
        transcriptBody(chip).attributes('id')
      );

      await transcriptToggle(chip).trigger('click');

      expect(transcriptBody(chip).exists()).toBe(false);
      expect(chip.text()).not.toContain(TRANSCRIPT);
      expect(transcriptToggle(chip).text()).toBe(
        'CONVERSATION.SHOW_TRANSCRIPT'
      );
    });

    it('sets the transcript close under its toggle, small and in italics', async () => {
      withContainerWidth(0);
      const chip = mountChip({ transcribedText: TRANSCRIPT });
      await flushPromises();

      await transcriptToggle(chip).trigger('click');

      const body = transcriptBody(chip);
      const classes = body.classes();
      // 12.5 px italic, the secondary ink colour
      expect(classes).toEqual(
        expect.arrayContaining(['text-ds-caption', 'italic', 'text-n-slate-11'])
      );
      // no padding around the text: 3 px above it, nothing below
      expect(classes.filter(name => /^p[a-z]?-/.test(name))).toEqual([]);
      expect(classes).not.toContain('text-sm');
      expect(classes).not.toContain('text-n-slate-12');
      // the toggle and the text sit in one group with a 3 px gap
      const group = body.element.parentElement;
      expect(group.classList.contains('gap-[3px]')).toBe(true);
      expect(group.contains(transcriptToggle(chip).element)).toBe(true);
    });

    it('keeps the compact look when the transcript is always shown (call accordion)', async () => {
      withContainerWidth(0);
      const chip = mountChip(
        { transcribedText: TRANSCRIPT },
        { collapseTranscript: false }
      );
      await flushPromises();

      expect(transcriptToggle(chip).exists()).toBe(false);
      expect(transcriptBody(chip).text()).toBe(TRANSCRIPT);
      expect(transcriptBody(chip).classes()).toEqual(
        expect.arrayContaining(['text-ds-caption', 'italic'])
      );
    });

    it('does not start playback when the toggle is used', async () => {
      withContainerWidth(0);
      const chip = mountChip({ transcribedText: TRANSCRIPT });
      await flushPromises();

      await transcriptToggle(chip).trigger('click');
      await flushPromises();

      expect(playSpy).not.toHaveBeenCalled();
    });

    it('renders neither toggle nor transcript without transcribed text', async () => {
      withContainerWidth(0);
      const chip = mountChip();
      await flushPromises();

      expect(transcriptToggle(chip).exists()).toBe(false);
      expect(transcriptBody(chip).exists()).toBe(false);
    });

    it('renders neither toggle nor transcript when the host hides transcripts', async () => {
      withContainerWidth(0);
      const chip = mountChip(
        { transcribedText: TRANSCRIPT },
        { showTranscribedText: false }
      );
      await flushPromises();

      expect(transcriptToggle(chip).exists()).toBe(false);
      expect(transcriptBody(chip).exists()).toBe(false);
      expect(chip.text()).not.toContain(TRANSCRIPT);
    });

    it('shows the transcript right away, without a toggle, when the host owns the collapsing', async () => {
      withContainerWidth(0);
      const chip = mountChip(
        { transcribedText: TRANSCRIPT },
        { collapseTranscript: false }
      );
      await flushPromises();

      expect(transcriptToggle(chip).exists()).toBe(false);
      expect(transcriptBody(chip).text()).toBe(TRANSCRIPT);
    });
  });
});
