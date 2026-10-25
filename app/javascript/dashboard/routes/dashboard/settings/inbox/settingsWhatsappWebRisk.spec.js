import { afterEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';

import InboxHealthAPI from 'dashboard/api/inboxHealth';
import WhatsappWebRiskNotice from './components/WhatsappWebRiskNotice.vue';
import Settings from './Settings.vue';

// The settings of a WhatsApp Web channel repeat the risk of the unofficial
// channel next to the number; the official WhatsApp channel has no such note.
const ACCOUNT_ID = 1;

const buildSettings = inbox =>
  shallowMount(Settings, {
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
        $route: { params: { accountId: ACCOUNT_ID, inboxId: inbox.id } },
        $router: { resolve: () => ({ href: '/' }), replace: vi.fn() },
      },
      directives: { 'on-clickaway': {} },
      stubs: {
        'woot-tabs': true,
        'woot-tabs-item': true,
        'woot-input': true,
        'woot-code': true,
        'woot-confirm-delete-modal': true,
        SettingIntroBanner: { template: '<div><slot /></div>' },
        SettingsAccordion: { template: '<div><slot /></div>' },
        SettingsFieldSection: { template: '<div><slot /></div>' },
        WhatsappWebRiskNotice: false,
        Banner: false,
      },
    },
  });

const notice = wrapper =>
  wrapper.find('[data-testid="whatsapp-web-risk-notice"]');

describe('WhatsApp Web risk notice in channel settings', () => {
  afterEach(() => vi.restoreAllMocks());

  it('is shown next to the number of a WhatsApp Web channel', async () => {
    const wrapper = buildSettings({
      id: 5,
      account_id: ACCOUNT_ID,
      name: 'Clinic WhatsApp',
      channel_type: 'Channel::WhatsappWeb',
      phone_number: '+77001234567',
      additional_attributes: {
        evolution: { status: 'connected', connection_state: 'open' },
      },
    });
    await flushPromises();

    expect(wrapper.findComponent(WhatsappWebRiskNotice).exists()).toBe(true);
    expect(notice(wrapper).text()).toContain(
      'Unofficial channel: WhatsApp may block the number'
    );
    wrapper.unmount();
  });

  it('is not shown for the official WhatsApp channel', async () => {
    vi.spyOn(InboxHealthAPI, 'getHealthStatus').mockResolvedValue({ data: {} });
    const wrapper = buildSettings({
      id: 11,
      account_id: ACCOUNT_ID,
      name: 'Clinic Cloud',
      channel_type: 'Channel::Whatsapp',
      provider: 'whatsapp_cloud',
      phone_number: '+77005550000',
      provider_config: { token_health: { status: 'healthy' } },
    });
    await flushPromises();

    expect(wrapper.findComponent(WhatsappWebRiskNotice).exists()).toBe(false);
    expect(notice(wrapper).exists()).toBe(false);
    wrapper.unmount();
  });
});
