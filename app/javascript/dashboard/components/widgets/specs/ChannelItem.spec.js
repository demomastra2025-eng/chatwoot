import { describe, expect, it } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import ChannelItem from '../ChannelItem.vue';

const channelSelectorStub = {
  name: 'ChannelSelector',
  props: ['disabled'],
  template: '<div />',
};

const createWrapper = ({
  channel,
  enabledFeatures = { channel_website: true },
  disabledChannels,
}) =>
  shallowMount(ChannelItem, {
    props: {
      channel: {
        title: 'WhatsApp Web',
        description: 'Custom WhatsApp-style channel',
        icon: 'i-woot-whatsapp',
        ...channel,
      },
      enabledFeatures,
      ...(disabledChannels !== undefined ? { disabledChannels } : {}),
    },
    global: {
      stubs: {
        ChannelSelector: channelSelectorStub,
      },
    },
  });

describe('ChannelItem.vue', () => {
  it('keeps whatsapp channel available in the inbox channel list', () => {
    const wrapper = createWrapper({
      channel: { key: 'whatsapp' },
    });

    expect(wrapper.vm.isActive).toBe(true);
    expect(wrapper.findComponent(channelSelectorStub).props('disabled')).toBe(
      false
    );
  });

  it.each(['tiktok', 'weixin', 'line', 'vk_community', 'twitter'])(
    'disables %s channel by default and prevents click',
    async channelKey => {
      const wrapper = createWrapper({
        channel: { key: channelKey },
      });

      expect(wrapper.vm.isActive).toBe(false);
      expect(wrapper.findComponent(channelSelectorStub).props('disabled')).toBe(
        true
      );

      await wrapper.findComponent(channelSelectorStub).trigger('click');
      expect(wrapper.emitted('channelItemClick')).toBeUndefined();
    }
  );

  it('keeps weixin channel available when not in disabledChannels', () => {
    const wrapper = createWrapper({
      channel: { key: 'weixin' },
      disabledChannels: [],
    });

    expect(wrapper.vm.isActive).toBe(true);
    expect(wrapper.findComponent(channelSelectorStub).props('disabled')).toBe(
      false
    );
  });
});
