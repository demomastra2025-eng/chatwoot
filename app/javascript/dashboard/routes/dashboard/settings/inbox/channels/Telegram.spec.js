import { shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import ChannelSelector from 'dashboard/components/ChannelSelector.vue';
import Telegram from './Telegram.vue';

const state = vi.hoisted(() => ({
  account: {},
  route: { name: 'settings_inboxes_page_channel', params: {}, query: {} },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => state.route,
  useRouter: () => ({ push: vi.fn() }),
}));

// The setup forms are not under test (and pull in the whole router)
vi.mock('./TelegramBot.vue', () => ({ default: { template: '<div />' } }));
vi.mock('./TelegramPersonal.vue', () => ({
  default: { template: '<div />' },
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ currentAccount: { value: state.account } }),
}));

const offeredProviders = () =>
  shallowMount(Telegram, { global: { mocks: { $t: key => key } } })
    .findAllComponents(ChannelSelector)
    .map(selector => selector.props('title'));

const BOT = 'INBOX_MGMT.ADD.AUTH.CHANNEL.TELEGRAM_BOT.TITLE';
const PERSONAL = 'INBOX_MGMT.ADD.AUTH.CHANNEL.TELEGRAM_PERSONAL.TITLE';

describe('Telegram channel setup: provider choice', () => {
  beforeEach(() => {
    state.account = { id: 1 };
  });

  it('offers both ways when the account payload has no available_channels (old cached copy)', () => {
    expect(offeredProviders()).toEqual([BOT, PERSONAL]);
  });

  it('offers both ways when both are available', () => {
    state.account.available_channels = ['telegram_bot', 'telegram_personal'];

    expect(offeredProviders()).toEqual([BOT, PERSONAL]);
  });

  it('hides the personal account when only the bot is available', () => {
    state.account.available_channels = ['telegram_bot'];

    expect(offeredProviders()).toEqual([BOT]);
  });

  it('hides the bot when only the personal account is available', () => {
    state.account.available_channels = ['telegram_personal'];

    expect(offeredProviders()).toEqual([PERSONAL]);
  });
});
