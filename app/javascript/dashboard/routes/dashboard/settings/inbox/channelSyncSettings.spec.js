import { describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Settings from './Settings.vue';
import DeveloperDetails from './components/DeveloperDetails.vue';

const mountSettings = channel => {
  const inbox = { id: 5, account_id: 1, name: 'Synthetic channel', ...channel };
  return shallowMount(Settings, {
    global: {
      mocks: {
        $store: {
          getters: {
            'inboxes/getUIFlags': { isFetching: false, isUpdating: false },
            'inboxes/getInbox': () => inbox,
            'inboxes/getInstagramInboxByInstagramId': () => undefined,
          },
          dispatch: vi.fn().mockResolvedValue({}),
        },
        $route: { params: { accountId: 1, inboxId: 5 } },
        $router: { resolve: () => ({ href: '/' }), replace: vi.fn() },
      },
      directives: { 'on-clickaway': {} },
      stubs: {
        SettingIntroBanner: { template: '<div><slot /></div>' },
        SettingsAccordion: { template: '<div><slot /></div>' },
        SettingsFieldSection: { template: '<div><slot /></div>' },
        DeveloperDetails: false,
        Accordion: false,
        NextButton: false,
      },
    },
  });
};

describe('channel sync settings', () => {
  it('saves business policies without replaying the retired settings of a legacy WhatsApp snapshot', async () => {
    const wrapper = mountSettings({
      channel_type: 'Channel::WhatsappWeb',
      phone_number: '+15550000001',
      import_contacts: false,
      import_messages: false,
      history_lookback_days: 7,
      sync_groups: false,
      ignore_jids: ['15550000002@s.whatsapp.net'],
    });
    await flushPromises();
    await wrapper
      .find('[data-testid="whatsapp-web-sync-groups-checkbox"]')
      .setValue(true);
    await wrapper.vm.updateInbox();
    const update = wrapper.vm.$store.dispatch.mock.calls.find(
      ([action]) => action === 'inboxes/updateInbox'
    );
    expect(update[1].channel).toMatchObject({
      sync_groups: true,
      ignore_jids: ['15550000002@s.whatsapp.net'],
    });
    expect(update[1].channel).not.toHaveProperty('import_contacts');
    expect(update[1].channel).not.toHaveProperty('import_messages');
    expect(update[1].channel).not.toHaveProperty('history_lookback_days');
    expect(wrapper.text()).toContain(
      'Messages and contacts are imported automatically.'
    );
    wrapper.unmount();
  });

  it('keeps Telegram reconnect but exposes no manual history or contacts action even after expanding technical details', async () => {
    const wrapper = mountSettings({
      channel_type: 'Channel::TelegramPersonal',
      phone_number: '+15550000001',
      connection_state: 'connected',
      lifecycle_state: 'connected',
      runtime_state: {
        history_sync_state: 'completed',
        contacts_sync_state: 'completed',
      },
    });
    await flushPromises();
    const technical = wrapper.findComponent(DeveloperDetails);
    await technical.find('button').trigger('click');
    const actions = wrapper.findAllComponents(NextButton);
    const labels = actions.map(button => button.props('label'));
    expect(labels).not.toContain(
      wrapper.vm.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.HISTORY_SYNC')
    );
    expect(labels).not.toContain(
      wrapper.vm.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.FULL_HISTORY_SYNC')
    );
    expect(labels).not.toContain(
      wrapper.vm.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.CONTACTS_SYNC')
    );
    const reconnect = actions.find(
      button =>
        button.props('label') ===
        wrapper.vm.$t('INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.RECONNECT')
    );
    expect(reconnect).toBeDefined();
    await reconnect.trigger('click');
    await flushPromises();
    expect(wrapper.vm.$store.dispatch).toHaveBeenCalledWith(
      'inboxes/reconnectTelegramPersonal',
      5
    );
    wrapper.unmount();
  });
});
