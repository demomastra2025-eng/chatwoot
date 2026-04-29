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
    },
    global: {
      stubs: {
        ChannelSelector: channelSelectorStub,
      },
    },
  });

describe('ChannelItem.vue', () => {
  it.each(['whatsapp', 'weixin'])(
    'keeps %s channel available in the inbox channel list',
    channelKey => {
      const wrapper = createWrapper({
        channel: { key: channelKey },
      });

      expect(wrapper.vm.isActive).toBe(true);
      expect(wrapper.findComponent(channelSelectorStub).props('disabled')).toBe(
        false
      );
    }
  );
});
