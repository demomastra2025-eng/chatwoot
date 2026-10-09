import { shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import ConversationSettings from './ConversationSettings.vue';

const { storeDispatch, accountState } = vi.hoisted(() => ({
  storeDispatch: vi.fn(() => Promise.resolve()),
  accountState: { current: { id: 1 } },
}));
let canManageWorkspace = true;

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: storeDispatch }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ currentAccount: { value: accountState.current } }),
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
        WorkspaceAssignmentPolicySettings: {
          template: '<div data-test="workspace-assignment-policy" />',
        },
        CaptainAiEditorSettings: {
          props: ['disabled'],
          template:
            '<div data-test="captain-ai-editor-settings" :data-disabled="String(disabled)" />',
        },
        MediaTranscription: {
          props: ['disabled'],
          template:
            '<div data-test="media-transcription" :data-disabled="String(disabled)" />',
        },
      },
    },
  });

describe('ConversationSettings', () => {
  beforeEach(() => {
    storeDispatch.mockClear();
    accountState.current = { id: 1 };
    canManageWorkspace = true;
  });

  it('loads account settings and shows transcription disabled for non-managers', () => {
    canManageWorkspace = false;
    const wrapper = mountComponent();

    expect(storeDispatch).not.toHaveBeenCalledWith('accounts/get');
    expect(
      wrapper
        .get('[data-test="media-transcription"]')
        .attributes('data-disabled')
    ).toBe('true');
    expect(
      wrapper
        .get('[data-test="captain-ai-editor-settings"]')
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
    expect(
      wrapper
        .get('[data-test="captain-ai-editor-settings"]')
        .attributes('data-disabled')
    ).toBe('false');
  });

  it('renders the workspace policy and AI settings without blocking on a page-wide fetch', () => {
    const wrapper = mountComponent();

    expect(
      wrapper.get('[data-test="workspace-assignment-policy"]')
    ).toBeTruthy();
    expect(wrapper.get('[data-test="captain-ai-editor-settings"]')).toBeTruthy();
    expect(wrapper.find('[data-test="conversation-settings-text-improvement"]').exists()).toBe(false);
  });

  it('fetches the account only when it is not already in the store', () => {
    accountState.current = {};
    mountComponent();

    expect(storeDispatch).toHaveBeenCalledWith('accounts/get');
  });
});
