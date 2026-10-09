import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import CaptainPreferencesAPI from 'dashboard/api/captain/preferences';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import CaptainAiEditorSettings from './CaptainAiEditorSettings.vue';

const { dispatch } = vi.hoisted(() => ({ dispatch: vi.fn() }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
}));

vi.mock('dashboard/api/captain/preferences', () => ({
  default: { get: vi.fn(), updatePreferences: vi.fn() },
}));

const mountComponent = props =>
  mount(CaptainAiEditorSettings, {
    props,
    global: {
      stubs: {
        SectionLayout: { template: '<section><slot /></section>' },
        Switch: {
          props: ['modelValue', 'disabled'],
          emits: ['change'],
          template:
            '<button :disabled="disabled" :data-on="String(modelValue)" @click="$emit(\'change\', !modelValue)" />',
        },
      },
    },
  });

describe('CaptainAiEditorSettings', () => {
  let store;

  beforeEach(() => {
    setActivePinia(createPinia());
    store = useCaptainConfigStore();
    dispatch.mockClear();
    vi.mocked(CaptainPreferencesAPI.get).mockReset();
    vi.mocked(CaptainPreferencesAPI.updatePreferences).mockReset();
    CaptainPreferencesAPI.get.mockResolvedValue({
      data: {
        features: {
          editor: { enabled: true },
          label_suggestion: { enabled: true },
        },
      },
    });
  });

  it('persists Text improvement under its own key and renders the saved off state', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    expect(wrapper.findAll('button').map(button => button.attributes('data-on'))).toEqual([
      'true',
      'true',
    ]);

    CaptainPreferencesAPI.updatePreferences.mockResolvedValueOnce({
      data: {
        features: {
          editor: { enabled: false },
          label_suggestion: { enabled: true },
        },
      },
    });
    await wrapper.findAll('button')[0].trigger('click');
    await flushPromises();

    expect(CaptainPreferencesAPI.updatePreferences).toHaveBeenCalledWith({
      captain_features: { text_improvement: false, label_suggestion: true },
    });
    expect(wrapper.findAll('button').map(button => button.attributes('data-on'))).toEqual([
      'false',
      'true',
    ]);
    expect(dispatch).toHaveBeenCalledWith('accounts/get');
  });

  it('persists Label suggestion from on to off and renders the saved off state', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    CaptainPreferencesAPI.updatePreferences.mockResolvedValueOnce({
      data: {
        features: {
          editor: { enabled: true },
          label_suggestion: { enabled: false },
        },
      },
    });

    await wrapper.findAll('button')[1].trigger('click');
    await flushPromises();

    expect(CaptainPreferencesAPI.updatePreferences).toHaveBeenCalledWith({
      captain_features: { text_improvement: true, label_suggestion: false },
    });
    expect(wrapper.findAll('button').map(button => button.attributes('data-on'))).toEqual([
      'true',
      'false',
    ]);
  });

  it('keeps both feature switches read-only for non-admin workspace users', async () => {
    const wrapper = mountComponent({ disabled: true });
    await flushPromises();

    expect(wrapper.findAll('button').every(button => button.element.disabled)).toBe(true);
    expect(CaptainPreferencesAPI.updatePreferences).not.toHaveBeenCalled();
  });

  it('offers a local retry after the account-scoped settings fetch fails', async () => {
    const fetch = vi.spyOn(store, 'fetch');
    CaptainPreferencesAPI.get
      .mockRejectedValueOnce(new Error('temporary error'))
      .mockResolvedValueOnce({ data: { features: { editor: { enabled: true } } } });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.get('[role="alert"]').text()).toContain(
      'CAPTAIN_SETTINGS.API.ERROR'
    );
    await wrapper.get('button').trigger('click');
    await flushPromises();

    expect(CaptainPreferencesAPI.get).toHaveBeenCalledTimes(2);
    expect(fetch).toHaveBeenLastCalledWith({
      clientMetadataOnly: true,
      force: true,
    });
    expect(wrapper.find('[role="alert"]').exists()).toBe(false);
  });

  it('queues both feature values when two toggles change before the first save completes', async () => {
    let resolveFirstSave;
    CaptainPreferencesAPI.updatePreferences.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveFirstSave = resolve;
        })
    );
    CaptainPreferencesAPI.updatePreferences.mockResolvedValueOnce({
      data: {
        features: {
          editor: { enabled: false },
          label_suggestion: { enabled: false },
        },
      },
    });

    const wrapper = mountComponent();
    await flushPromises();
    const switches = wrapper.findAllComponents({ name: 'Switch' });

    switches[0].vm.$emit('change', false);
    switches[1].vm.$emit('change', false);
    await flushPromises();

    expect(CaptainPreferencesAPI.updatePreferences).toHaveBeenCalledTimes(1);
    expect(CaptainPreferencesAPI.updatePreferences).toHaveBeenNthCalledWith(1, {
      captain_features: { text_improvement: false, label_suggestion: true },
    });

    resolveFirstSave({
      data: {
        features: {
          editor: { enabled: false },
          label_suggestion: { enabled: true },
        },
      },
    });
    await flushPromises();

    expect(CaptainPreferencesAPI.updatePreferences).toHaveBeenCalledTimes(2);
    expect(CaptainPreferencesAPI.updatePreferences).toHaveBeenNthCalledWith(2, {
      captain_features: { text_improvement: false, label_suggestion: false },
    });
    expect(wrapper.findAll('button').map(button => button.attributes('data-on'))).toEqual([
      'false',
      'false',
    ]);
  });
});
