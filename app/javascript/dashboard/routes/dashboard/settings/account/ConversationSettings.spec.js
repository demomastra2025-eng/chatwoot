import { flushPromises, shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import ConversationSettings from './ConversationSettings.vue';

const { storeDispatch, alertMock } = vi.hoisted(() => ({
  storeDispatch: vi.fn(() => Promise.resolve()),
  alertMock: vi.fn(),
}));
let canManageWorkspace = true;

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: storeDispatch }),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({
    checkPermissions: () => canManageWorkspace,
  }),
}));

const mountComponent = () =>
  shallowMount(ConversationSettings, {
    global: {
      stubs: {
        SettingsLayout: {
          template: '<main><slot name="header" /><slot name="body" /></main>',
        },
        BaseSettingsHeader: true,
        MediaTranscription: {
          props: ['disabled'],
          template:
            '<div data-test="media-transcription" :data-disabled="String(disabled)" />',
        },
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
    canManageWorkspace = true;
  });

  it('loads account settings and shows transcription disabled for non-managers', () => {
    canManageWorkspace = false;
    const wrapper = mountComponent();

    expect(storeDispatch).toHaveBeenCalledWith('accounts/get');
    expect(
      wrapper
        .get('[data-test="media-transcription"]')
        .attributes('data-disabled')
    ).toBe('true');
  });

  it('enables transcription for workspace managers', () => {
    const wrapper = mountComponent();

    expect(
      wrapper
        .get('[data-test="media-transcription"]')
        .attributes('data-disabled')
    ).toBe('false');
  });

  it('saves text improvement under its own key and refreshes the account', async () => {
    const updateSpy = vi
      .spyOn(configStore, 'updatePreferences')
      .mockResolvedValue({ data: {} });
    const wrapper = mountComponent();
    storeDispatch.mockClear();
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
    storeDispatch.mockClear();

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
