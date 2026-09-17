import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { ref } from 'vue';

import MediaTranscription from './MediaTranscription.vue';
import { useAlert } from 'dashboard/composables';

const updateAccount = vi.fn();
const currentAccount = ref({
  settings: {
    audio_transcriptions: false,
    call_transcriptions: true,
  },
});

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ currentAccount, updateAccount }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

const buildWrapper = () =>
  shallowMount(MediaTranscription, {
    global: {
      renderStubDefaultSlot: true,
      mocks: { $t: key => key },
      stubs: {
        Switch: {
          props: ['modelValue'],
          emits: ['change'],
          template:
            '<button class="switch" @click="$emit(\'change\', !modelValue)" />',
        },
      },
    },
  });

describe('MediaTranscription', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    updateAccount.mockResolvedValue();
    currentAccount.value = {
      settings: {
        audio_transcriptions: false,
        call_transcriptions: true,
      },
    };
  });

  it('exposes independent workspace settings for voice messages and calls', () => {
    const wrapper = buildWrapper();

    expect(wrapper.vm.audioTranscriptionsEnabled).toBe(false);
    expect(wrapper.vm.callTranscriptionsEnabled).toBe(true);
  });

  it('shows the legacy voice setting for calls until a dedicated value exists', () => {
    currentAccount.value = {
      settings: { audio_transcriptions: true },
    };

    const wrapper = buildWrapper();

    expect(wrapper.vm.callTranscriptionsEnabled).toBe(true);
  });

  it('updates one setting without changing the other', async () => {
    const wrapper = buildWrapper();

    await wrapper.findAll('.switch')[0].trigger('click');
    await flushPromises();

    expect(updateAccount).toHaveBeenCalledWith(
      { audio_transcriptions: true },
      { silent: true }
    );
    expect(useAlert).toHaveBeenCalledWith('Transcription settings updated');
  });
});
