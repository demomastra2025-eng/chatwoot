import { flushPromises, shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { useInboxStore } from 'dashboard/stores/inboxes';

import WhatsAppTemplatesPage from './WhatsAppTemplatesPage.vue';

const { permissionState, useAlertMock } = vi.hoisted(() => ({
  permissionState: { canManage: true },
  useAlertMock: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: useAlertMock,
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => permissionState.canManage }),
}));

const inbox = {
  id: 7,
  message_templates: [],
  csat_config: {},
};
let pinia;
let syncTemplates;

const mountComponent = (inboxProp = inbox) =>
  shallowMount(WhatsAppTemplatesPage, {
    props: { inbox: inboxProp, embedded: true },
    global: {
      plugins: [pinia],
      stubs: {
        Button: true,
        CreateWhatsAppTemplateDialog: true,
        Dialog: true,
        Input: true,
      },
    },
  });

const syncedInbox = {
  ...inbox,
  message_templates: [
    {
      name: 'synced_order_update',
      language: 'en_US',
      status: 'APPROVED',
      category: 'UTILITY',
      components: [{ type: 'BODY', text: 'Your order was updated' }],
    },
  ],
};

describe('WhatsAppTemplatesPage', () => {
  beforeEach(() => {
    pinia = createPinia();
    setActivePinia(pinia);
    syncTemplates = vi.spyOn(useInboxStore(), 'syncTemplates');
    permissionState.canManage = true;
    useAlertMock.mockReset();
  });

  it('refreshes the visible template list from the updated store prop', async () => {
    const wrapper = mountComponent();
    syncTemplates.mockImplementation(async () => {
      await wrapper.setProps({ inbox: syncedInbox });
      return syncedInbox;
    });

    expect(wrapper.text()).not.toContain('synced_order_update');

    await wrapper.vm.syncTemplates();
    await flushPromises();

    expect(syncTemplates).toHaveBeenCalledWith(7);
    expect(wrapper.text()).toContain('synced_order_update');
    expect(useAlertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_SUCCESS'
    );
  });

  it('renders later updates for the same inbox after sync', async () => {
    const wrapper = mountComponent(syncedInbox);

    await wrapper.setProps({
      inbox: {
        ...syncedInbox,
        message_templates: [
          ...syncedInbox.message_templates,
          {
            name: 'new_same_inbox_template',
            language: 'en_US',
            status: 'APPROVED',
            category: 'UTILITY',
            components: [{ type: 'BODY', text: 'New template' }],
          },
        ],
      },
    });

    expect(wrapper.text()).toContain('new_same_inbox_template');
  });

  it('does not render builder or last-sync explanatory text', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).not.toContain(
      'WHATSAPP_TEMPLATES.MANAGEMENT.SUPPORTED_TITLE'
    );
    expect(wrapper.text()).not.toContain(
      'WHATSAPP_TEMPLATES.MANAGEMENT.SUPPORTED_DESCRIPTION'
    );
    expect(wrapper.text()).not.toContain(
      'WHATSAPP_TEMPLATES.MANAGEMENT.LAST_SYNC'
    );
  });

  it('does not expose template mutations to regular agents', async () => {
    permissionState.canManage = false;
    const wrapper = mountComponent(syncedInbox);

    await wrapper.vm.syncTemplates();
    wrapper.vm.openCreateDialog();
    await flushPromises();

    expect(syncTemplates).not.toHaveBeenCalled();
    expect(wrapper.findAllComponents({ name: 'Button' })).toHaveLength(0);
    expect(wrapper.findComponent({ name: 'Dialog' }).exists()).toBe(false);
  });
});
