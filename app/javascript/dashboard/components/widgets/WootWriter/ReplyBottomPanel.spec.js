import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { describe, expect, it, vi } from 'vitest';

import ReplyBottomPanel from './ReplyBottomPanel.vue';

vi.mock('activestorage', () => ({
  start: vi.fn(),
}));

vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    setSignatureFlagForInbox: vi.fn(),
    fetchSignatureFlagFromUISettings: vi.fn(() => false),
  }),
}));

vi.mock('dashboard/composables/useWhatsappCallInitiation', () => ({
  useWhatsappCallInitiation: () => ({
    canInitiateWhatsappCall: false,
    initiateWhatsappCall: vi.fn(),
    isInitiatingWhatsappCall: false,
  }),
}));

const whatsappChannel = {
  conversation_id: 11,
  inbox_id: 101,
  inbox_name: 'WhatsApp',
  channel: 'Channel::WhatsappWeb',
  can_reply: true,
};

const telegramChannel = {
  conversation_id: 22,
  inbox_id: 202,
  inbox_name: 'Telegram',
  channel: 'Channel::Telegram',
  can_reply: false,
};

const NextButtonStub = {
  name: 'NextButton',
  props: ['label', 'icon', 'disabled', 'type'],
  emits: ['click'],
  template: `
    <button
      v-bind="$attrs"
      :type="type || 'button'"
      :data-icon="icon"
      :disabled="disabled"
      @click="$emit('click')"
    >
      <span v-if="icon" class="button-icon">{{ icon }}</span>
      <span v-if="label">{{ label }}</span>
    </button>
  `,
};

const createVuexStore = () =>
  createStore({
    getters: {
      getCurrentAccountId: () => 1,
      getConversationById: () => () => ({ meta: { sender: {} } }),
    },
    modules: {
      accounts: {
        namespaced: true,
        getters: {
          isFeatureEnabledonAccount: () => () => false,
        },
      },
      integrations: {
        namespaced: true,
        getters: {
          getUIFlags: () => ({ isFetching: false }),
        },
      },
    },
  });

const mountComponent = props =>
  shallowMount(ReplyBottomPanel, {
    props: {
      conversationId: 11,
      inbox: { channel_type: 'Channel::WhatsappWeb' },
      portalSlug: '',
      sendButtonText: 'Send (↵)',
      onSend: vi.fn(),
      showCommunicationChannelSelector: true,
      communicationChannels: [whatsappChannel, telegramChannel],
      activeReplyChannel: whatsappChannel,
      ...props,
    },
    global: {
      plugins: [createVuexStore()],
      mocks: {
        $t: (key, params = {}) =>
          ({
            'CONVERSATION.COMMUNICATION_THREAD.REPLY_VIA': 'Reply via',
            'CONVERSATION.COMMUNICATION_THREAD.ACTIVE_CHANNEL': `Active channel: ${params.channel}`,
            'CONVERSATION.COMMUNICATION_THREAD.REPLY_RESTRICTED_SUFFIX':
              '(reply restricted)',
          })[key] || key,
      },
      directives: {
        onClickaway: () => {},
      },
      stubs: {
        FileUpload: { template: '<div><slot /></div>' },
        NextButton: NextButtonStub,
        PaymentActionButton: true,
        VideoCallButton: true,
        VoiceCallButton: true,
        'fluent-icon': true,
      },
    },
  });

describe('ReplyBottomPanel', () => {
  it('shows selected communication channel as an icon on the send dropdown button', async () => {
    const onSend = vi.fn();
    const wrapper = mountComponent({ onSend });

    const sendButton = wrapper.find('button[type="submit"]');
    const channelToggle = wrapper.find('.reply-channel-menu__toggle');
    expect(channelToggle.attributes('data-icon')).toBe('i-ri-whatsapp-fill');
    expect(channelToggle.text()).not.toContain('WhatsApp');
    expect(sendButton.text()).toContain('Send (↵)');
    expect(sendButton.text()).not.toContain('WhatsApp');

    await sendButton.trigger('click');
    expect(onSend).toHaveBeenCalledTimes(1);
  });

  it('moves communication channel selection into the send button dropdown', async () => {
    const wrapper = mountComponent();

    expect(wrapper.find('#communication-reply-channel').exists()).toBe(false);

    await wrapper.find('.reply-channel-menu__toggle').trigger('click');

    expect(wrapper.find('.reply-channel-menu').exists()).toBe(true);
    const channelItems = wrapper.findAll('.reply-channel-menu__item');
    expect(channelItems).toHaveLength(2);
    expect(channelItems[1].text()).toContain('Telegram');
    expect(channelItems[1].text()).toContain('(reply restricted)');

    await channelItems[1].trigger('click');

    expect(wrapper.emitted('selectReplyChannel')).toEqual([[22]]);
    expect(wrapper.find('.reply-channel-menu').exists()).toBe(false);
  });

  it('keeps the channel dropdown usable when the current send action is disabled', async () => {
    const wrapper = mountComponent({ isSendDisabled: true });

    expect(
      wrapper.find('button[type="submit"]').attributes('disabled')
    ).toBeDefined();

    await wrapper.find('.reply-channel-menu__toggle').trigger('click');
    await wrapper.findAll('.reply-channel-menu__item')[1].trigger('click');

    expect(wrapper.emitted('selectReplyChannel')).toEqual([[22]]);
  });

  it('renders the voice call action when the conversation contact has a phone number', () => {
    const wrapper = mountComponent({
      contactId: 42,
      contactPhone: '+77066318623',
      inbox: { channel_type: 'Channel::Voice' },
    });

    const voiceCallButton = wrapper.findComponent({ name: 'VoiceCallButton' });
    expect(voiceCallButton.exists()).toBe(true);
    expect(voiceCallButton.props('contactId')).toBe(42);
    expect(voiceCallButton.props('phone')).toBe('+77066318623');
  });
});
