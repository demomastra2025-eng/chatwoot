import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';

const mocks = vi.hoisted(() => ({
  alerts: vi.fn(),
  createVoice: vi.fn(),
  deleteVoice: vi.fn(),
  getVoices: vi.fn(),
  refreshVoice: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => `${key}${params ? JSON.stringify(params) : ''}`,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mocks.alerts(...args),
}));

vi.mock('dashboard/api/captain/fishVoices', () => ({
  default: {
    createVoice: (...args) => mocks.createVoice(...args),
    delete: (...args) => mocks.deleteVoice(...args),
    get: (...args) => mocks.getVoices(...args),
    refresh: (...args) => mocks.refreshVoice(...args),
  },
}));

const { default: FishVoiceManager } = await import('./FishVoiceManager.vue');

const trainedVoice = {
  id: 17,
  reference_id: 'fish-trained-id',
  title: 'Sales voice',
  state: 'trained',
  visibility: 'private',
  in_use: false,
  selected_assistants_count: 0,
};

const buildWrapper = (props = {}) =>
  shallowMount(FishVoiceManager, {
    props: { modelValue: '', ...props },
    global: {
      stubs: {
        Button: true,
        Checkbox: true,
        Dialog: true,
        Input: true,
        Select: true,
      },
    },
  });

describe('FishVoiceManager', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getVoices.mockResolvedValue({ data: { payload: [] } });
  });

  it('loads only account-managed voices on mount', async () => {
    mocks.getVoices.mockResolvedValue({ data: { payload: [trainedVoice] } });

    const wrapper = buildWrapper();
    await flushPromises();

    expect(mocks.getVoices).toHaveBeenCalledOnce();
    expect(wrapper.vm.voices).toEqual([trainedVoice]);
  });

  it('clones an authorized audio sample and selects it when ready', async () => {
    mocks.createVoice.mockResolvedValue({ data: { payload: trainedVoice } });
    const wrapper = buildWrapper();
    await flushPromises();
    const voiceFile = new File(['voice'], 'voice.mp3', { type: 'audio/mpeg' });
    wrapper.vm.cloneForm.title = 'Sales voice';
    wrapper.vm.cloneForm.transcript = 'Hello';
    wrapper.vm.cloneForm.voice = voiceFile;
    wrapper.vm.cloneForm.consentConfirmed = true;

    await wrapper.vm.createVoice();

    expect(mocks.createVoice).toHaveBeenCalledWith({
      title: 'Sales voice',
      voice: voiceFile,
      transcript: 'Hello',
      consentConfirmed: true,
    });
    expect(wrapper.emitted('update:modelValue')).toEqual([['fish-trained-id']]);
  });

  it('deletes an unused managed voice and falls back from an unsaved selection', async () => {
    mocks.getVoices.mockResolvedValue({ data: { payload: [trainedVoice] } });
    mocks.deleteVoice.mockResolvedValue({});
    const wrapper = buildWrapper({ modelValue: trainedVoice.reference_id });
    await flushPromises();

    wrapper.vm.openDeleteDialog(trainedVoice);
    await wrapper.vm.deleteVoice();

    expect(mocks.deleteVoice).toHaveBeenCalledWith(trainedVoice.id);
    expect(wrapper.vm.voices).toEqual([]);
    expect(wrapper.emitted('update:modelValue')).toEqual([
      ['31f936a9333f4f5a99dcaaf6df091b84'],
    ]);
  });

  it('does not resurrect a deleted voice from an earlier polling response', async () => {
    const pendingVoice = { ...trainedVoice, state: 'training' };
    let resolveRefresh;
    mocks.refreshVoice.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveRefresh = resolve;
        })
    );
    mocks.deleteVoice.mockResolvedValue({});
    const wrapper = buildWrapper();
    await flushPromises();
    wrapper.vm.voices = [pendingVoice];

    const refreshPromise = wrapper.vm.refreshPendingVoices();
    await vi.waitFor(() =>
      expect(mocks.refreshVoice).toHaveBeenCalledWith(pendingVoice.id)
    );
    wrapper.vm.openDeleteDialog(pendingVoice);
    await wrapper.vm.deleteVoice();
    resolveRefresh({ data: { payload: trainedVoice } });
    await refreshPromise;

    expect(wrapper.vm.voices).toEqual([]);
  });
});
