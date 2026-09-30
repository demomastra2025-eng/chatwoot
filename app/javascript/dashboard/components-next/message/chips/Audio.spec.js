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
vi.mock('dashboard/composables/emitter', () => ({ useEmitter: vi.fn() }));
vi.mock('@chatwoot/utils', () => ({ downloadFile: vi.fn() }));

import AudioChip from './Audio.vue';

const RECORDING_URL =
  '/api/v1/accounts/77/telephony/calls/sipuni%3Alocal%3Aabc/recording?recording_token=signed';

let wrapper;

const mountChip = () => {
  wrapper = mount(AudioChip, {
    props: {
      attachment: {
        id: 'voice-recordings/janus/77/call/recording.wav',
        fileType: 'audio',
        extension: 'wav',
        dataUrl: RECORDING_URL,
      },
    },
    global: { stubs: { Icon: true } },
  });
  return wrapper;
};

const playButton = chipWrapper => chipWrapper.findAll('button')[0];

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
});
