import { flushPromises, shallowMount } from '@vue/test-utils';

import WhatsAppTemplatesPage from './WhatsAppTemplatesPage.vue';

const { dispatch, permissionState, useAlertMock } = vi.hoisted(() => ({
  dispatch: vi.fn(),
  permissionState: { canManage: true },
  useAlertMock: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: useAlertMock,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => permissionState.canManage }),
}));

const inbox = {
  id: 7,
  message_templates: [],
  csat_config: {},
};

const mountComponent = (inboxProp = inbox) =>
  shallowMount(WhatsAppTemplatesPage, {
    props: { inbox: inboxProp, embedded: true },
    global: {
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
    dispatch.mockReset();
    permissionState.canManage = true;
    useAlertMock.mockReset();
  });

  it('refreshes the visible template list from the updated store prop', async () => {
    const wrapper = mountComponent();
    dispatch.mockImplementation(async () => {
      await wrapper.setProps({ inbox: syncedInbox });
      return syncedInbox;
    });

    expect(wrapper.text()).not.toContain('synced_order_update');

    await wrapper.vm.syncTemplates();
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('inboxes/syncTemplates', 7);
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

    expect(dispatch).not.toHaveBeenCalled();
    expect(wrapper.findAllComponents({ name: 'Button' })).toHaveLength(0);
    expect(wrapper.findComponent({ name: 'Dialog' }).exists()).toBe(false);
  });
});
