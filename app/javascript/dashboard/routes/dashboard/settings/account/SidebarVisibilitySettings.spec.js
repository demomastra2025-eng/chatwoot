import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';

import SidebarVisibilitySettings from './SidebarVisibilitySettings.vue';
import {
  SIDEBAR_ORDER_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_ITEMS,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
} from 'dashboard/components-next/sidebar/sidebarVisibility';

const currentAccount = ref({ settings: {} });
const updateAccount = vi.fn();
const useAlert = vi.fn();
const defaultItemOrder = SIDEBAR_VISIBILITY_ITEMS.map(item => item.key);

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
        Draggable: {
          props: ['modelValue'],
          emits: ['update:modelValue'],
          template:
            '<div data-test="sidebar-order-list"><slot v-for="(element, index) in modelValue" name="item" :element="element" :index="index" /></div>',
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

  it('shows only top-level workspace navigation sections', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('SIDEBAR.INBOX');
    expect(wrapper.text()).toContain('SIDEBAR.CONVERSATIONS');
    expect(wrapper.text()).toContain('SIDEBAR.ADDITIONAL');

    expect(wrapper.text()).not.toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.PIPELINE'
    );
    expect(wrapper.text()).not.toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENTS'
    );
  });

  it('saves one account-wide visibility policy', async () => {
    const wrapper = mountComponent();

    wrapper.vm.visibilityDraft.Reports = false;
    wrapper.vm.visibilityDraft['Conversation:Pipelines'] = false;
    await wrapper.vm.saveSidebarVisibility();

    expect(updateAccount).toHaveBeenCalledWith({
      [SIDEBAR_ORDER_UI_SETTINGS_KEY]: defaultItemOrder,
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: expect.arrayContaining([
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
        [SIDEBAR_ORDER_UI_SETTINGS_KEY]: ['Contacts', 'Conversation'],
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Campaigns:MassBroadcasts'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      },
    };

    const wrapper = mountComponent();

    expect(wrapper.vm.visibilityDraft['Campaigns:MassBroadcasts']).toBe(false);
    expect(wrapper.vm.visibilityDraft.Reports).toBe(true);
    expect(wrapper.vm.draftItemOrder.slice(0, 3)).toEqual([
      'Contacts',
      'Conversation',
      'Inbox',
    ]);
  });

  it('moves a section and saves the new menu order', async () => {
    const wrapper = mountComponent();

    await wrapper
      .findAll('[data-test="sidebar-order-down"]')[3]
      .trigger('click');

    expect(wrapper.vm.draftItemOrder.slice(3, 5)).toEqual([
      'Contacts',
      'Captain',
    ]);
    expect(wrapper.vm.hasChanges).toBe(true);

    await wrapper.vm.saveSidebarVisibility();

    expect(updateAccount).toHaveBeenCalledWith(
      expect.objectContaining({
        [SIDEBAR_ORDER_UI_SETTINGS_KEY]: [
          ...defaultItemOrder.slice(0, 3),
          'Contacts',
          'Captain',
          ...defaultItemOrder.slice(5),
        ],
      })
    );
  });

  it('keeps Settings visible and leaves conversation details to their own page', () => {
    const wrapper = mountComponent();

    expect(
      wrapper.find('#workspace-sidebar-visibility-settings').exists()
    ).toBe(false);

    expect(
      wrapper
        .find('#workspace-sidebar-visibility-conversation-pipelines')
        .exists()
    ).toBe(false);
  });
});
