import { shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import ChannelSelector from 'dashboard/components/ChannelSelector.vue';
import Whatsapp from './Whatsapp.vue';

const state = vi.hoisted(() => ({
  account: {},
  route: { name: 'settings_inboxes_page_channel', params: {}, query: {} },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
  I18nT: { template: '<span />' },
}));

vi.mock('vue-router', () => ({
  useRoute: () => state.route,
  useRouter: () => ({ push: vi.fn() }),
}));

// The setup forms are not under test (and pull in the whole router)
vi.mock('./Twilio.vue', () => ({ default: { template: '<div />' } }));
vi.mock('./360DialogWhatsapp.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('./CloudWhatsapp.vue', () => ({ default: { template: '<div />' } }));
vi.mock('./WhatsappEmbeddedSignup.vue', () => ({
  default: { template: '<div />' },
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ currentAccount: { value: state.account } }),
}));

const offeredProviders = () =>
  shallowMount(Whatsapp, { global: { mocks: { $t: key => key } } })
    .findAllComponents(ChannelSelector)
    .map(selector => selector.props('title'));

const CLOUD = 'INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.WHATSAPP_CLOUD';
const TWILIO = 'INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.TWILIO';
const WEB = 'INBOX_MGMT.ADD.AUTH.CHANNEL.WHATSAPP_WEB.TITLE';

describe('WhatsApp channel setup: provider choice', () => {
  beforeEach(() => {
    state.account = { id: 1 };
  });

  it('offers all three ways when the account payload has no available_channels (old cached copy)', () => {
    expect(offeredProviders()).toEqual([CLOUD, TWILIO, WEB]);
  });

  it('offers all three ways when all are available', () => {
    state.account.available_channels = [
      'whatsapp_cloud',
      'whatsapp_twilio',
      'whatsapp_web',
    ];

    expect(offeredProviders()).toEqual([CLOUD, TWILIO, WEB]);
  });

  it('hides the ways the platform does not allow', () => {
    state.account.available_channels = ['whatsapp_cloud', 'whatsapp_web'];
    expect(offeredProviders()).toEqual([CLOUD, WEB]);

    state.account.available_channels = ['whatsapp_twilio'];
    expect(offeredProviders()).toEqual([TWILIO]);
  });

  it('offers nothing when none of the ways is available', () => {
    state.account.available_channels = ['website'];

    expect(offeredProviders()).toEqual([]);
  });
});
