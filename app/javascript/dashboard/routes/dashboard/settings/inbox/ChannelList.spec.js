import { shallowMount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import ChannelItem from 'dashboard/components/widgets/ChannelItem.vue';
import ChannelList from './ChannelList.vue';

const accountState = vi.hoisted(() => ({ account: {} }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ name: 'settings_inboxes_page_channel', params: {} }),
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ({ value: {} }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountId: { value: 1 },
    currentAccount: { value: accountState.account },
  }),
}));

const ALL_TILES = [
  'website',
  'facebook',
  'twitter',
  'whatsapp',
  'sms',
  'email',
  'api',
  'telegram',
  'weixin',
  'vk_community',
  'line',
  'instagram',
  'voice',
];

const shownTiles = () =>
  shallowMount(ChannelList)
    .findAllComponents(ChannelItem)
    .map(item => item.props('channel').key);

describe('ChannelList', () => {
  beforeEach(() => {
    accountState.account = { id: 1, features: { channel_website: true } };
  });

  afterEach(() => {
    delete window.chatwootConfig;
  });

  it('offers every tile when the account payload has no available_channels (old cached copy)', () => {
    expect(shownTiles()).toEqual(ALL_TILES);
  });

  it('hides the tiles that are not in available_channels instead of greying them out', () => {
    accountState.account.available_channels = ['website', 'email', 'voice'];

    expect(shownTiles()).toEqual(['website', 'email', 'voice']);
  });

  it('shows nothing when the list is empty', () => {
    accountState.account.available_channels = [];

    expect(shownTiles()).toEqual([]);
  });

  it('keeps the WhatsApp tile while any of its ways is available', () => {
    accountState.account.available_channels = ['whatsapp_web'];
    expect(shownTiles()).toEqual(['whatsapp']);

    accountState.account.available_channels = ['whatsapp_twilio'];
    expect(shownTiles()).toEqual(['whatsapp']);

    accountState.account.available_channels = ['whatsapp_cloud'];
    expect(shownTiles()).toEqual(['whatsapp']);
  });

  it('hides the WhatsApp tile when none of its ways is available', () => {
    accountState.account.available_channels = ['website', 'telegram_bot'];

    expect(shownTiles()).toEqual(['website', 'telegram']);
  });

  it('keeps the Telegram tile for the bot or the personal account', () => {
    accountState.account.available_channels = ['telegram_personal'];

    expect(shownTiles()).toEqual(['telegram']);
  });

  it('lists TikTok only when the app is configured and the channel is available', () => {
    window.chatwootConfig = { tiktokAppId: 'tiktok-app' };
    accountState.account.available_channels = ['website'];
    expect(shownTiles()).toEqual(['website']);

    accountState.account.available_channels = ['website', 'tiktok'];
    expect(shownTiles()).toEqual(['website', 'tiktok']);

    delete window.chatwootConfig;
    expect(shownTiles()).toEqual(['website']);
  });
});
