import { mount, flushPromises } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { nextTick } from 'vue';
import { createStore } from 'vuex';

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
          load: vi.fn(() => new Promise(() => {})),
          destroy: vi.fn(),
          setMuted: vi.fn(),
          getMuted: vi.fn(() => false),
          setPlaybackRate: vi.fn(),
          getDuration: vi.fn(() => 32.5),
          getCurrentTime: vi.fn(() => 0),
          playPause: vi.fn(() => {
            handlers.play?.();
            return Promise.resolve();
          }),
          pause: vi.fn(() => handlers.pause?.()),
        };
        waveSurferState.instances.push(instance);
        return markRaw(instance);
      }),
    },
  };
});

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('@chatwoot/utils', () => ({ downloadFile: vi.fn() }));
vi.mock('vue-router', () => ({
  useRoute: () => ({
    fullPath: '/app/accounts/77/conversations/77',
    params: { accountId: '77' },
  }),
}));

import AudioChip from './Audio.vue';
import { useAudioPlaybackState } from '../audioPlaybackState';

// The same recording rendered twice, e.g. in a search result and in the live
// conversation: both chips share one attachment id.
const ATTACHMENT = {
  id: 'voice-recordings/janus/77/call/recording.wav',
  fileType: 'audio',
  extension: 'wav',
  dataUrl:
    '/api/v1/accounts/77/telephony/calls/sipuni%3Alocal%3Aabc/recording?recording_token=signed',
};

let wrappers = [];

const mountChip = () => {
  const store = createStore({
    state: {
      conversations: { selectedChatType: 'conversation' },
    },
    getters: { getSelectedChat: () => ({ id: 77 }) },
    actions: { fetchAllAttachments: vi.fn() },
  });
  const chipWrapper = mount(AudioChip, {
    props: { attachment: { ...ATTACHMENT } },
    global: { plugins: [store], stubs: { Icon: true } },
    attachTo: document.body,
  });
  wrappers.push(chipWrapper);
  return chipWrapper;
};

const playButton = chipWrapper => chipWrapper.findAll('button')[0];

const recursionMessages = spy =>
  spy.mock.calls
    .map(args => args.map(String).join(' '))
    .filter(message => /Maximum recursive updates/i.test(message));

describe('Audio chips sharing one attachment id', () => {
  let warnSpy;
  let errorSpy;
  let widthSpy;
  let playSpy;

  beforeEach(() => {
    waveSurferState.instances.length = 0;
    warnSpy = vi.spyOn(console, 'warn');
    errorSpy = vi.spyOn(console, 'error');
    playSpy = vi
      .spyOn(window.HTMLMediaElement.prototype, 'play')
      .mockImplementation(function play() {
        this.dispatchEvent(new Event('play'));
        return Promise.resolve();
      });
    vi.spyOn(window.HTMLMediaElement.prototype, 'pause').mockImplementation(
      function pause() {
        this.dispatchEvent(new Event('pause'));
      }
    );
    vi.spyOn(window.HTMLMediaElement.prototype, 'load').mockImplementation(
      () => {}
    );
    vi.stubGlobal('requestAnimationFrame', cb => {
      queueMicrotask(() => cb(0));
      return 1;
    });
    vi.stubGlobal('cancelAnimationFrame', () => {});
  });

  afterEach(() => {
    wrappers.forEach(chipWrapper => chipWrapper.unmount());
    wrappers = [];
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

  const expectNoRecursion = () => {
    expect(recursionMessages(warnSpy)).toEqual([]);
    expect(recursionMessages(errorSpy)).toEqual([]);
  };

  it('plays one chip before the waveform is ready without an update loop', async () => {
    withContainerWidth(0);
    const first = mountChip();
    const second = mountChip();
    await flushPromises();

    await playButton(first).trigger('click');
    await flushPromises();
    await nextTick();

    expectNoRecursion();
    expect(playSpy).toHaveBeenCalledTimes(1);
    expect(useAudioPlaybackState(ATTACHMENT.id).value.isPlaying).toBe(true);

    // Starting the twin pauses the first one, still without a loop.
    await playButton(second).trigger('click');
    await flushPromises();
    await nextTick();

    expectNoRecursion();
    expect(playSpy).toHaveBeenCalledTimes(2);
    // The speed button is shown only while a chip is playing.
    expect(first.text()).not.toContain('1x');
    expect(second.text()).toContain('1x');
    expect(useAudioPlaybackState(ATTACHMENT.id).value.isPlaying).toBe(true);
  });

  it('plays one chip after the waveform is ready without an update loop', async () => {
    withContainerWidth(300);
    const first = mountChip();
    const second = mountChip();
    await flushPromises();

    expect(waveSurferState.instances).toHaveLength(2);
    waveSurferState.instances.forEach(instance =>
      instance.handlers.ready(32.5)
    );
    await flushPromises();

    await playButton(first).trigger('click');
    await flushPromises();
    waveSurferState.instances[0].handlers.timeupdate(1.5);
    await flushPromises();
    await nextTick();

    expectNoRecursion();
    expect(waveSurferState.instances[0].playPause).toHaveBeenCalledTimes(1);

    await playButton(second).trigger('click');
    await flushPromises();
    await nextTick();

    expectNoRecursion();
    expect(waveSurferState.instances[1].playPause).toHaveBeenCalledTimes(1);
    expect(waveSurferState.instances[0].pause).toHaveBeenCalled();
    expect(first.text()).not.toContain('1x');
    expect(second.text()).toContain('1x');
  });

  it('keeps the twin state when one of the chips unmounts', async () => {
    withContainerWidth(0);
    const first = mountChip();
    mountChip();
    await flushPromises();

    await playButton(first).trigger('click');
    await flushPromises();
    expect(useAudioPlaybackState(ATTACHMENT.id).value.isPlaying).toBe(true);

    wrappers[1].unmount();
    wrappers.splice(1, 1);
    await nextTick();

    expectNoRecursion();
    expect(useAudioPlaybackState(ATTACHMENT.id).value.isPlaying).toBe(true);
  });
});
