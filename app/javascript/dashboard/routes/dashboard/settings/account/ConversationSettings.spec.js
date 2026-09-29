import { flushPromises, shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import ConversationSettings from './ConversationSettings.vue';

const { storeDispatch, alertMock } = vi.hoisted(() => ({
  storeDispatch: vi.fn(() => Promise.resolve()),
  alertMock: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: storeDispatch }),
}));

const mountComponent = () =>
  shallowMount(ConversationSettings, {
    global: {
      stubs: {
        SettingsLayout: {
          template: '<main><slot name="header" /><slot name="body" /></main>',
        },
        BaseSettingsHeader: true,
        Switch: {
          name: 'Switch',
          props: ['modelValue'],
          emits: ['change'],
          template:
            '<button data-test="conversation-settings-text-improvement" :data-on="String(modelValue)" @click="$emit(\'change\', !modelValue)" />',
        },
      },
    },
  });

describe('ConversationSettings', () => {
  let configStore;

  beforeEach(() => {
    setActivePinia(createPinia());
    configStore = useCaptainConfigStore();
    vi.spyOn(configStore, 'fetch').mockResolvedValue();
    configStore.applyPayload({
      features: { editor: { models: [], enabled: true } },
    });
    storeDispatch.mockClear();
    alertMock.mockClear();
  });

  it('saves text improvement under its own key and refreshes the account', async () => {
    const updateSpy = vi
      .spyOn(configStore, 'updatePreferences')
      .mockResolvedValue({ data: {} });
    const wrapper = mountComponent();
    const toggle = wrapper.get(
      '[data-test="conversation-settings-text-improvement"]'
    );
    expect(toggle.attributes('data-on')).toBe('true');

    await toggle.trigger('click');
    await flushPromises();

    expect(updateSpy).toHaveBeenCalledWith({
      captain_features: { text_improvement: false },
    });
    expect(storeDispatch).toHaveBeenCalledWith('accounts/get');
    expect(alertMock).toHaveBeenCalledWith(
      'GENERAL_SETTINGS.CONVERSATIONS.UPDATE_SUCCESS'
    );
  });

  it('reports a failed save without refreshing the account', async () => {
    vi.spyOn(configStore, 'updatePreferences').mockRejectedValue(
      new Error('boom')
    );
    const wrapper = mountComponent();

    await wrapper
      .get('[data-test="conversation-settings-text-improvement"]')
      .trigger('click');
    await flushPromises();

    expect(storeDispatch).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'GENERAL_SETTINGS.CONVERSATIONS.UPDATE_ERROR'
    );
  });
});
