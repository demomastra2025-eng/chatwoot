import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { describe, expect, it, vi } from 'vitest';
import { useAlert } from 'dashboard/composables';

import ReplyBottomPanel from './ReplyBottomPanel.vue';

const useWhatsappCallInitiationMock = vi.fn(() => ({
  canInitiateWhatsappCall: false,
  initiateWhatsappCall: vi.fn(),
  isInitiatingWhatsappCall: false,
}));

vi.mock('activestorage', () => ({
  start: vi.fn(),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
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
  useWhatsappCallInitiation: options => useWhatsappCallInitiationMock(options),
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

const voiceChannel = {
  conversation_id: 33,
  inbox_id: 4593,
  inbox_name: 'Voice',
  channel: 'Channel::Voice',
  can_reply: true,
};

const whatsappOfficialCallChannel = {
  conversation_id: 44,
  inbox_id: 404,
  inbox_name: 'WhatsApp Official',
  channel: 'Channel::Whatsapp',
  can_reply: true,
  can_send_text: true,
  can_call: true,
  media_server_enabled: true,
  channel_key: 'conversation:44',
};

const whatsappOfficialCallAction = {
  ...whatsappOfficialCallChannel,
  communication_action: 'call',
  message_channel_key: 'conversation:44',
  channel_key: 'conversation:44:action:call',
  can_send_text: false,
  can_send_attachments: false,
  requires_template: false,
  disabled: false,
  disabled_reason: null,
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

const createVuexStore = ({
  captainEnabled = false,
  conversations = { 11: { meta: { sender: {} } } },
  inboxes = {},
  currentUser = null,
  actions = {},
} = {}) =>
  createStore({
    getters: {
      getCurrentAccountId: () => 1,
      getConversationById: () => conversationId =>
        conversations[conversationId] || null,
      getCurrentUser: () => currentUser,
    },
    actions: {
      toggleStatus: (_context, payload) => actions.toggleStatus?.(payload),
      setCurrentChatAssignee: (_context, payload) =>
        actions.setCurrentChatAssignee?.(payload),
      assignAgent: (_context, payload) => actions.assignAgent?.(payload),
    },
    modules: {
      accounts: {
        namespaced: true,
        getters: {
          isFeatureEnabledonAccount: () => () => captainEnabled,
        },
      },
      inboxes: {
        namespaced: true,
        getters: {
          getInbox: () => inboxId => inboxes[inboxId] || null,
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

const mountComponent = (props, storeOptions) =>
  shallowMount(ReplyBottomPanel, {
    props: {
      conversationId: 11,
      inbox: { channel_type: 'Channel::WhatsappWeb' },
      portalSlug: '',
      sendButtonText: 'Send (↵)',
      onSend: vi.fn(),
      showCommunicationChannelSelector: true,
      communicationChannels: [whatsappChannel, telegramChannel, voiceChannel],
      activeReplyChannel: whatsappChannel,
      ...props,
    },
    global: {
      plugins: [createVuexStore(storeOptions)],
      mocks: {
        $t: (key, params = {}) =>
          ({
            'CONVERSATION.COMMUNICATION_THREAD.REPLY_VIA': 'Reply via',
            'CONVERSATION.COMMUNICATION_THREAD.ACTIVE_CHANNEL': `Active channel: ${params.channel}`,
            'CONVERSATION.COMMUNICATION_THREAD.REPLY_RESTRICTED_SUFFIX':
              '(reply restricted)',
            'CONVERSATION.COMMUNICATION_THREAD.CALL_ACTION': 'Call',
            'CONVERSATION.COMMUNICATION_THREAD.WRITE_ACTION': 'Write',
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
  it('keeps the direct-channel Captain status contract unchanged', async () => {
    const toggleStatus = vi.fn();
    const wrapper = mountComponent(
      {
        conversationId: 11,
        isCommunicationThread: false,
        inbox: { id: 101, captain_assistant: { id: 5, name: 'Captain' } },
      },
      {
        captainEnabled: true,
        conversations: {
          11: { id: 11, status: 'open', meta: { assignee: null } },
        },
        actions: { toggleStatus },
      }
    );

    const captainButton = wrapper.find('[data-icon="i-woot-captain"]');
    expect(captainButton.exists()).toBe(true);
    expect(captainButton.attributes('aria-pressed')).toBe('false');

    await wrapper.vm.toggleCaptainForConversation();

    expect(toggleStatus).toHaveBeenCalledWith({
      conversationId: 11,
      status: 'pending',
    });
  });

  it('keeps direct-channel Captain disable and assignment unchanged', async () => {
    const actions = {
      toggleStatus: vi.fn(),
      setCurrentChatAssignee: vi.fn(),
      assignAgent: vi.fn(),
    };
    const wrapper = mountComponent(
      {
        conversationId: 11,
        isCommunicationThread: false,
        inbox: { id: 101, captain_assistant: { id: 5, name: 'Captain' } },
      },
      {
        captainEnabled: true,
        currentUser: { id: 7, name: 'Agent', avatar_url: '/agent.png' },
        conversations: {
          11: { id: 11, status: 'pending', meta: { assignee: null } },
        },
        actions,
      }
    );

    expect(
      wrapper.find('[data-icon="i-woot-captain"]').attributes('aria-pressed')
    ).toBe('true');

    await wrapper.vm.toggleCaptainForConversation();

    expect(actions.toggleStatus).toHaveBeenCalledWith({
      conversationId: 11,
      status: 'open',
    });
    expect(actions.setCurrentChatAssignee).not.toHaveBeenCalled();
    expect(actions.assignAgent).toHaveBeenCalledWith({
      conversationId: 11,
      agentId: 7,
      throwOnError: true,
    });
  });

  it('disables Captain for the selected communication-thread channel', async () => {
    const actions = {
      toggleStatus: vi.fn(),
      setCurrentChatAssignee: vi.fn(),
      assignAgent: vi.fn(),
    };
    const currentUser = {
      id: 7,
      name: 'Agent',
      avatar_url: '/agent.png',
    };
    const selectedChannel = {
      ...whatsappChannel,
      status: 'pending',
    };
    const wrapper = mountComponent(
      {
        conversationId: 999,
        isCommunicationThread: true,
        activeReplyChannel: selectedChannel,
      },
      {
        captainEnabled: true,
        currentUser,
        conversations: {
          11: { id: 11, status: 'open', meta: { assignee: null } },
        },
        inboxes: {
          101: { id: 101, captain_assistant: { id: 5, name: 'Captain' } },
        },
        actions,
      }
    );

    const captainButton = wrapper.find('[data-icon="i-woot-captain"]');
    expect(captainButton.exists()).toBe(true);
    expect(captainButton.attributes('aria-pressed')).toBe('true');

    await wrapper.vm.toggleCaptainForConversation();

    expect(actions.toggleStatus).toHaveBeenCalledWith({
      conversationId: 11,
      conversationType: 'conversation',
      status: 'open',
    });
    expect(actions.setCurrentChatAssignee).not.toHaveBeenCalled();
    expect(actions.assignAgent).toHaveBeenCalledWith({
      conversationId: 11,
      conversationType: 'conversation',
      agentId: 7,
      throwOnError: true,
    });
  });

  it('reports assignment failure without applying an optimistic assignee', async () => {
    vi.mocked(useAlert).mockClear();
    const actions = {
      toggleStatus: vi.fn(),
      setCurrentChatAssignee: vi.fn(),
      assignAgent: vi.fn().mockRejectedValue(new Error('assignment failed')),
    };
    const wrapper = mountComponent(
      {
        conversationId: 999,
        isCommunicationThread: true,
        activeReplyChannel: { ...whatsappChannel, status: 'pending' },
      },
      {
        captainEnabled: true,
        currentUser: { id: 7, name: 'Agent' },
        conversations: {
          11: { id: 11, status: 'open', meta: { assignee: null } },
        },
        inboxes: {
          101: { id: 101, captain_assistant: { id: 5, name: 'Captain' } },
        },
        actions,
      }
    );

    await wrapper.vm.toggleCaptainForConversation();

    expect(actions.setCurrentChatAssignee).not.toHaveBeenCalled();
    expect(useAlert).toHaveBeenCalledWith(
      'CONVERSATION.REPLYBOX.BOT_HANDOFF_ERROR'
    );
    expect(wrapper.vm.isTogglingCaptain).toBe(false);
  });

  it('keeps the original channel assignment target during an in-flight toggle', async () => {
    let resolveStatusToggle;
    const actions = {
      toggleStatus: vi.fn(
        () =>
          new Promise(resolve => {
            resolveStatusToggle = resolve;
          })
      ),
      assignAgent: vi.fn(),
    };
    const currentUser = { id: 7, name: 'Agent' };
    const wrapper = mountComponent(
      {
        conversationId: 999,
        isCommunicationThread: true,
        activeReplyChannel: { ...whatsappChannel, status: 'pending' },
      },
      {
        captainEnabled: true,
        currentUser,
        conversations: {
          11: { id: 11, status: 'open', meta: { assignee: null } },
          22: { id: 22, status: 'pending', meta: { assignee: currentUser } },
        },
        inboxes: {
          101: { id: 101, captain_assistant: { id: 5, name: 'Captain' } },
          202: { id: 202, captain_assistant: { id: 6, name: 'Captain 2' } },
        },
        actions,
      }
    );

    const togglePromise = wrapper.vm.toggleCaptainForConversation();
    await wrapper.setProps({
      activeReplyChannel: {
        ...telegramChannel,
        can_reply: true,
        status: 'pending',
      },
    });
    resolveStatusToggle();
    await togglePromise;

    expect(actions.assignAgent).toHaveBeenCalledWith({
      conversationId: 11,
      conversationType: 'conversation',
      agentId: 7,
      throwOnError: true,
    });
  });

  it('enables Captain for the selected open communication-thread channel', async () => {
    const toggleStatus = vi.fn();
    const selectedChannel = {
      ...telegramChannel,
      can_reply: true,
      status: 'open',
    };
    const wrapper = mountComponent(
      {
        conversationId: 999,
        isCommunicationThread: true,
        activeReplyChannel: selectedChannel,
      },
      {
        captainEnabled: true,
        conversations: {
          22: { id: 22, status: 'pending', meta: { assignee: null } },
        },
        inboxes: {
          202: { id: 202, captain_assistant: { id: 6, name: 'Captain 2' } },
        },
        actions: { toggleStatus },
      }
    );

    const captainButton = wrapper.find('[data-icon="i-woot-captain"]');
    expect(captainButton.exists()).toBe(true);
    expect(captainButton.attributes('aria-pressed')).toBe('false');

    await wrapper.vm.toggleCaptainForConversation();

    expect(toggleStatus).toHaveBeenCalledWith({
      conversationId: 22,
      conversationType: 'conversation',
      status: 'pending',
    });
  });

  it('reacts to selected channel status while the native record stays stale', async () => {
    const selectedChannel = {
      ...telegramChannel,
      can_reply: true,
      status: 'open',
    };
    const wrapper = mountComponent(
      {
        conversationId: 999,
        isCommunicationThread: true,
        activeReplyChannel: selectedChannel,
      },
      {
        captainEnabled: true,
        conversations: {
          22: { id: 22, status: 'open', meta: { assignee: null } },
        },
        inboxes: {
          202: { id: 202, captain_assistant: { id: 6, name: 'Captain 2' } },
        },
      }
    );

    const captainButton = wrapper.find('[data-icon="i-woot-captain"]');
    expect(captainButton.attributes('aria-pressed')).toBe('false');

    await wrapper.setProps({
      activeReplyChannel: { ...selectedChannel, status: 'pending' },
    });

    expect(captainButton.attributes('aria-pressed')).toBe('true');
  });

  it('hides Captain when the selected channel inbox has no assistant', () => {
    const wrapper = mountComponent(
      {
        conversationId: 999,
        isCommunicationThread: true,
        activeReplyChannel: whatsappChannel,
        inbox: { id: 999, captain_assistant: { id: 55 } },
      },
      {
        captainEnabled: true,
        inboxes: { 101: { id: 101 } },
      }
    );

    expect(wrapper.find('[data-icon="i-woot-captain"]').exists()).toBe(false);
  });

  it('passes selected conversation and inbox context to WhatsApp call initiation', () => {
    mountComponent({
      conversationId: 481,
      inbox: {
        id: 57,
        channel_type: 'Channel::Whatsapp',
        provider: 'whatsapp_cloud',
      },
    });

    const [options] = useWhatsappCallInitiationMock.mock.calls.at(-1);
    expect(options.conversationId.value).toBe(481);
    expect(options.inboxId.value).toBe(57);
  });

  it('shows selected communication channel as an icon on the send dropdown button', async () => {
    const onSend = vi.fn();
    const wrapper = mountComponent({ onSend });

    const sendButton = wrapper.find('button[type="submit"]');
    const channelToggle = wrapper.find('.reply-channel-menu__toggle');
    expect(channelToggle.attributes('data-icon')).toBe(
      'i-woot-whatsapp channel-icon-neutral'
    );
    expect(sendButton.attributes('data-icon')).toBeUndefined();
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
    expect(channelItems[0].text()).toContain('Voice');
    expect(channelItems[1].text()).toContain('WhatsApp');
    expect(channelItems.map(item => item.text()).join(' ')).not.toContain(
      'Telegram'
    );
    expect(channelItems[0].find('.reply-channel-menu__icon').classes()).toEqual(
      expect.arrayContaining(['i-woot-voice', 'channel-icon-neutral'])
    );

    await channelItems[0].trigger('click');

    expect(wrapper.emitted('selectReplyChannel')).toEqual([[33]]);
    expect(wrapper.find('.reply-channel-menu').exists()).toBe(false);
  });

  it('keeps the channel dropdown usable when the current send action is disabled', async () => {
    const wrapper = mountComponent({ isSendDisabled: true });

    expect(
      wrapper.find('button[type="submit"]').attributes('disabled')
    ).toBeDefined();

    await wrapper.find('.reply-channel-menu__toggle').trigger('click');
    await wrapper.findAll('.reply-channel-menu__item')[0].trigger('click');

    expect(wrapper.emitted('selectReplyChannel')).toEqual([[33]]);
  });

  it('uses the primary call action and hides the extra call icon for communication-thread voice replies', () => {
    const wrapper = mountComponent({
      isCommunicationThread: true,
      sendButtonText: 'Позвонить',
      contactId: 42,
      contactPhone: '+770****8623',
      communicationChannels: [voiceChannel, whatsappChannel],
      activeReplyChannel: voiceChannel,
    });

    const voiceCallButtons = wrapper.findAllComponents({
      name: 'VoiceCallButton',
    });
    expect(voiceCallButtons).toHaveLength(1);
    expect(voiceCallButtons[0].props()).toMatchObject({
      label: 'Позвонить',
      contactId: 42,
      phone: '+770****8623',
      inboxId: 4593,
      disabled: false,
    });
    expect(voiceCallButtons[0].props('icon')).toBe('');
    expect(wrapper.find('button[type="submit"]').exists()).toBe(false);
  });

  it('uses the primary call action for selected WhatsApp Official call replies', async () => {
    const initiateWhatsappCall = vi.fn();
    useWhatsappCallInitiationMock.mockReturnValueOnce({
      canInitiateWhatsappCall: true,
      initiateWhatsappCall,
      isInitiatingWhatsappCall: false,
    });

    const wrapper = mountComponent({
      isCommunicationThread: true,
      sendButtonText: 'Call',
      conversationId: 44,
      contactId: 42,
      contactPhone: '+770****8623',
      communicationChannels: [whatsappOfficialCallChannel],
      activeReplyChannel: whatsappOfficialCallAction,
      inbox: {
        id: 404,
        channel_type: 'Channel::Whatsapp',
        provider: 'whatsapp_cloud',
      },
    });

    const [options] = useWhatsappCallInitiationMock.mock.calls.at(-1);
    expect(options.conversationId.value).toBe(44);
    expect(options.inboxId.value).toBe(404);
    expect(options.callingEnabled.value).toBe(true);
    expect(options.mediaServerEnabled.value).toBe(true);

    const primaryButton = wrapper.find('.reply-send-button');
    expect(primaryButton.text()).toContain('Call');
    expect(wrapper.findComponent({ name: 'VoiceCallButton' }).exists()).toBe(
      false
    );

    await primaryButton.trigger('click');
    expect(initiateWhatsappCall).toHaveBeenCalledTimes(1);
  });

  it('shows write and call variants for WhatsApp Official in the reply dropdown', async () => {
    const wrapper = mountComponent({
      isCommunicationThread: true,
      communicationChannels: [whatsappOfficialCallChannel],
      activeReplyChannel: whatsappOfficialCallChannel,
    });

    await wrapper.find('.reply-channel-menu__toggle').trigger('click');

    const channelItems = wrapper.findAll('.reply-channel-menu__item');
    expect(channelItems).toHaveLength(2);
    expect(channelItems[0].text()).toContain('WhatsApp Official - Write');
    expect(channelItems[1].text()).toContain('WhatsApp Official - Call');

    await channelItems[1].trigger('click');

    expect(wrapper.emitted('selectReplyChannel')).toEqual([
      ['conversation:44:action:call'],
    ]);
  });

  it('shows direct WhatsApp Official write and call variants in the send dropdown', async () => {
    const wrapper = mountComponent({
      showCommunicationChannelSelector: false,
      isCommunicationThread: false,
      communicationChannels: [],
      activeReplyChannel: null,
      inbox: {
        id: 404,
        name: 'WhatsApp Official',
        channel_type: 'Channel::Whatsapp',
        provider: 'whatsapp_cloud',
        calling_enabled: true,
      },
    });

    expect(wrapper.find('.reply-channel-menu__toggle').exists()).toBe(true);
    expect(wrapper.find('[data-icon="i-ph-phone"]').exists()).toBe(false);

    await wrapper.find('.reply-channel-menu__toggle').trigger('click');

    const channelItems = wrapper.findAll('.reply-channel-menu__item');
    expect(channelItems).toHaveLength(2);
    expect(channelItems[0].text()).toContain('WhatsApp Official - Write');
    expect(channelItems[1].text()).toContain('WhatsApp Official - Call');

    await channelItems[1].trigger('click');

    expect(wrapper.emitted('selectDirectReplyAction')).toEqual([['call']]);
    expect(wrapper.emitted('selectReplyChannel')).toBeUndefined();
  });

  it('uses the primary call action for selected direct WhatsApp Official call replies', async () => {
    const initiateWhatsappCall = vi.fn();
    useWhatsappCallInitiationMock.mockReturnValueOnce({
      canInitiateWhatsappCall: true,
      initiateWhatsappCall,
      isInitiatingWhatsappCall: false,
    });

    const wrapper = mountComponent({
      showCommunicationChannelSelector: false,
      isCommunicationThread: false,
      communicationChannels: [],
      activeReplyChannel: null,
      directReplyAction: 'call',
      sendButtonText: 'Call',
      contactId: 42,
      contactPhone: '+770****8623',
      inbox: {
        id: 404,
        name: 'WhatsApp Official',
        channel_type: 'Channel::Whatsapp',
        provider: 'whatsapp_cloud',
        calling_enabled: true,
      },
    });

    const primaryButton = wrapper.find('.reply-send-button');
    expect(primaryButton.text()).toContain('Call');
    expect(primaryButton.attributes('type')).toBe('button');
    expect(wrapper.findComponent({ name: 'VoiceCallButton' }).exists()).toBe(
      false
    );

    await primaryButton.trigger('click');
    expect(initiateWhatsappCall).toHaveBeenCalledTimes(1);
  });

  it('uses normal private-note send action when a voice channel is selected', async () => {
    const onSend = vi.fn();
    const wrapper = mountComponent({
      isCommunicationThread: true,
      isNote: true,
      isOnPrivateNote: true,
      sendButtonText: 'Заметка (↵)',
      contactId: 42,
      contactPhone: '+770****8623',
      communicationChannels: [voiceChannel, whatsappChannel],
      activeReplyChannel: voiceChannel,
      onSend,
    });

    expect(wrapper.findComponent({ name: 'VoiceCallButton' }).exists()).toBe(
      false
    );

    const sendButton = wrapper.find('button[type="submit"]');
    expect(sendButton.exists()).toBe(true);
    expect(sendButton.text()).toContain('Заметка (↵)');
    expect(sendButton.attributes('disabled')).toBeUndefined();

    await sendButton.trigger('click');
    expect(onSend).toHaveBeenCalledTimes(1);
  });

  it('uses the primary call action and hides the extra call icon for direct voice inboxes', () => {
    const wrapper = mountComponent({
      isCommunicationThread: false,
      sendButtonText: 'Позвонить',
      contactId: 42,
      contactPhone: '+77066318623',
      inbox: { id: 4593, channel_type: 'Channel::Voice' },
      activeReplyChannel: null,
      showCommunicationChannelSelector: false,
    });

    const voiceCallButtons = wrapper.findAllComponents({
      name: 'VoiceCallButton',
    });
    expect(voiceCallButtons).toHaveLength(1);
    expect(voiceCallButtons[0].props()).toMatchObject({
      label: 'Позвонить',
      contactId: 42,
      phone: '+77066318623',
      inboxId: 4593,
      disabled: false,
    });
    expect(voiceCallButtons[0].props('icon')).toBe('');
    expect(wrapper.find('button[type="submit"]').exists()).toBe(false);
  });
});
