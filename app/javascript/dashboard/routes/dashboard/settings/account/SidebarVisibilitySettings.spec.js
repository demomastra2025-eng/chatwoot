import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';

import SidebarVisibilitySettings from './SidebarVisibilitySettings.vue';
import {
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
} from 'dashboard/components-next/sidebar/sidebarVisibility';

const currentAccount = ref({ settings: {} });
const updateAccount = vi.fn();
const useAlert = vi.fn();

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: message => useAlert(message),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount,
    updateAccount,
  }),
}));

const mountComponent = () =>
  shallowMount(SidebarVisibilitySettings, {
    global: {
      stubs: {
        BaseSettingsHeader: {
          props: ['title', 'description'],
          template:
            '<header data-test="settings-header" :data-title="title" :data-description="description" />',
        },
        SettingsLayout: {
          template:
            '<section><slot name="header" /><slot name="body" /><slot /></section>',
        },
        Checkbox: {
          props: ['id', 'modelValue', 'disabled'],
          emits: ['update:modelValue'],
          template:
            '<input data-test="visibility-checkbox" type="checkbox" :id="id" :checked="modelValue" :disabled="disabled" @change="$emit(\'update:modelValue\', $event.target.checked)" />',
        },
        Button: true,
      },
    },
  });

describe('SidebarVisibilitySettings', () => {
  beforeEach(() => {
    currentAccount.value = { settings: {} };
    updateAccount.mockReset();
    updateAccount.mockResolvedValue();
    useAlert.mockReset();
  });

  it('shows all workspace sidebar sections, including conversation visibility', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('SIDEBAR.INBOX');
    expect(wrapper.text()).toContain('SIDEBAR.CONVERSATIONS');
    expect(wrapper.text()).toContain('SIDEBAR.ADDITIONAL');

    wrapper.vm.expandedSections = { Conversation: true };

    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.PIPELINE'
    );
    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENTS'
    );
  });

  it('saves one account-wide visibility policy', async () => {
    const wrapper = mountComponent();

    wrapper.vm.visibilityDraft.Reports = false;
    wrapper.vm.visibilityDraft['Conversation:Pipelines'] = false;
    await wrapper.vm.saveSidebarVisibility();

    expect(updateAccount).toHaveBeenCalledWith({
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: expect.arrayContaining([
        'Conversation:Statuses',
        'Conversation:Pipelines',
        'Reports',
      ]),
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    });
    expect(useAlert).toHaveBeenCalledWith(
      'GENERAL_SETTINGS.SIDEBAR_VISIBILITY.UPDATE_SUCCESS'
    );
  });

  it('hydrates the draft from workspace settings', () => {
    currentAccount.value = {
      settings: {
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Campaigns'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      },
    };

    const wrapper = mountComponent();

    expect(wrapper.vm.visibilityDraft.Campaigns).toBe(false);
    expect(wrapper.vm.visibilityDraft.Reports).toBe(true);
  });

  it('keeps visibility management reachable and reflects runtime hierarchy', async () => {
    const wrapper = mountComponent();

    expect(
      wrapper.find('#workspace-sidebar-visibility-settings').exists()
    ).toBe(false);

    wrapper.vm.expandedSections = { Conversation: true };
    wrapper.vm.visibilityDraft['Conversation:Statuses'] = false;
    await wrapper.vm.$nextTick();

    expect(
      wrapper
        .find('#workspace-sidebar-visibility-conversation-open')
        .attributes('disabled')
    ).toBeDefined();
    expect(
      wrapper
        .find(
          '#workspace-sidebar-visibility-conversation-appointmentstatus-scheduled'
        )
        .attributes('disabled')
    ).toBeUndefined();
  });
});
