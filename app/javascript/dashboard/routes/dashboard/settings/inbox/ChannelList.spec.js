import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import ChannelList from './ChannelList.vue';

const originalChatwootConfig = window.chatwootConfig;

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ name: 'settings_inbox_new' }),
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ({ value: { apiChannelName: 'API' } }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountId: { value: 1 },
    currentAccount: { value: { features: {} } },
  }),
}));

describe('ChannelList.vue', () => {
  beforeEach(() => {
    window.chatwootConfig = undefined;
  });

  afterEach(() => {
    window.chatwootConfig = originalChatwootConfig;
    vi.restoreAllMocks();
  });

  it('filters out disabled channels by default (tiktok, weixin, line, vk_community, twitter)', () => {
    const wrapper = shallowMount(ChannelList);
    const keys = wrapper.vm.channelList.map(c => c.key);

    expect(keys).not.toContain('tiktok');
    expect(keys).not.toContain('weixin');
    expect(keys).not.toContain('line');
    expect(keys).not.toContain('vk_community');
    expect(keys).not.toContain('twitter');
    expect(keys).toContain('website');
    expect(keys).toContain('facebook');
    expect(keys).toContain('whatsapp');
  });

  it('filters out only channels in custom window.chatwootConfig.disabledChannels', () => {
    window.chatwootConfig = {
      disabledChannels: ['twitter'],
    };

    const wrapper = shallowMount(ChannelList);
    const keys = wrapper.vm.channelList.map(c => c.key);

    expect(keys).not.toContain('twitter');
    expect(keys).toContain('weixin');
    expect(keys).toContain('line');
    expect(keys).toContain('vk_community');
    expect(keys).toContain('website');
  });

  it('shows all channels when disabledChannels is empty', () => {
    window.chatwootConfig = {
      disabledChannels: [],
      tiktokAppId: 'test_app_id',
    };

    const wrapper = shallowMount(ChannelList);
    const keys = wrapper.vm.channelList.map(c => c.key);

    expect(keys).toContain('tiktok');
    expect(keys).toContain('weixin');
    expect(keys).toContain('line');
    expect(keys).toContain('vk_community');
    expect(keys).toContain('twitter');
  });
});
