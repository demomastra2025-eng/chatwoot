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
      mocks: { $t: key => key },
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

  it('shows configurable sections without a notification row', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('[data-test="sidebar-order-pinned"]').exists()).toBe(
      false
    );
    expect(wrapper.text()).not.toContain('SIDEBAR.INBOX');
    expect(wrapper.text()).toContain('SIDEBAR.CONVERSATIONS');
    expect(wrapper.text()).toContain('SIDEBAR.MASS_BROADCASTS');
    expect(wrapper.text()).not.toContain('SIDEBAR.OUTBOUND');
    expect(wrapper.text()).toContain('SIDEBAR.ADDITIONAL');
    expect(wrapper.text()).not.toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.PIPELINE'
    );
    expect(
      wrapper.findAll('[data-test="sidebar-order-drag-handle"]')
    ).toHaveLength(defaultItemOrder.length);
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

  it('keeps conversation navigation choices when saving the menu', async () => {
    currentAccount.value = {
      settings: {
        [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: ['Conversation:Teams'],
        [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
          SIDEBAR_VISIBILITY_CURRENT_VERSION,
      },
    };
    const wrapper = mountComponent();

    wrapper.vm.visibilityDraft.Contacts = false;
    await wrapper.vm.saveSidebarVisibility();

    expect(
      updateAccount.mock.calls[0][0][SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]
    ).toEqual(['Conversation:Teams', 'Contacts']);
  });

  it('reports a failed save', async () => {
    updateAccount.mockRejectedValue(new Error('failed'));
    const wrapper = mountComponent();

    await wrapper.vm.saveSidebarVisibility();

    expect(useAlert).toHaveBeenCalledWith(
      'GENERAL_SETTINGS.SIDEBAR_VISIBILITY.UPDATE_ERROR'
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
      'Campaigns:MassBroadcasts',
    ]);
    expect(wrapper.vm.hasChanges).toBe(false);
  });

  it.each([7, 17, 20])(
    'opens a version %s menu with the old outbound group as broadcasts and saves it as version 21',
    async version => {
      currentAccount.value = {
        settings: {
          [SIDEBAR_ORDER_UI_SETTINGS_KEY]: [
            'Contacts',
            'Campaigns',
            'Conversation',
          ],
          [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
            'Campaigns',
            'Conversation:Statuses',
          ],
          [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]: version,
        },
      };

      const wrapper = mountComponent();

      expect(wrapper.vm.visibilityDraft['Campaigns:MassBroadcasts']).toBe(
        false
      );
      expect(wrapper.vm.visibilityDraft.Campaigns).toBeUndefined();
      expect(wrapper.vm.draftItemOrder.slice(0, 3)).toEqual([
        'Contacts',
        'Campaigns:MassBroadcasts',
        'Conversation',
      ]);
      expect(wrapper.text()).not.toContain('SIDEBAR.OUTBOUND');

      await wrapper.vm.saveSidebarVisibility();

      const payload = updateAccount.mock.calls[0][0];
      expect(payload[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]).toEqual([
        'Campaigns:MassBroadcasts',
      ]);
      expect(payload[SIDEBAR_ORDER_UI_SETTINGS_KEY].slice(0, 3)).toEqual([
        'Contacts',
        'Campaigns:MassBroadcasts',
        'Conversation',
      ]);
      expect(payload[SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]).toBe(21);
    }
  );

  it('moves a section with the arrow buttons and saves the new order', async () => {
    const wrapper = mountComponent();

    await wrapper
      .findAll('[data-test="sidebar-order-down"]')[2]
      .trigger('click');

    expect(wrapper.vm.draftItemOrder.slice(2, 4)).toEqual([
      'Contacts',
      'Captain',
    ]);
    expect(wrapper.vm.hasChanges).toBe(true);

    await wrapper.vm.saveSidebarVisibility();

    expect(updateAccount).toHaveBeenCalledWith(
      expect.objectContaining({
        [SIDEBAR_ORDER_UI_SETTINGS_KEY]: [
          ...defaultItemOrder.slice(0, 2),
          'Contacts',
          'Captain',
          ...defaultItemOrder.slice(4),
        ],
      })
    );
  });

  it('disables moving the first item up and the last item down', () => {
    const wrapper = mountComponent();
    const upButtons = wrapper.findAll('[data-test="sidebar-order-up"]');
    const downButtons = wrapper.findAll('[data-test="sidebar-order-down"]');

    expect(upButtons[0].attributes('disabled')).toBeDefined();
    expect(downButtons.at(-1).attributes('disabled')).toBeDefined();
  });

  it('keeps Settings always visible', () => {
    const wrapper = mountComponent();

    expect(
      wrapper.find('#workspace-sidebar-visibility-settings').exists()
    ).toBe(false);
  });
});
