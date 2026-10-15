import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';

import Message from './Message.vue';
import { MESSAGE_STATUS, MESSAGE_TYPES } from './constants';

vi.mock('@vueuse/core', () => ({
  useTimeoutFn: vi.fn(),
}));

vi.mock('dashboard/composables', () => ({
  useTrack: vi.fn(),
}));

const useMapGetterMock = vi.fn();
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: (...args) => useMapGetterMock(...args),
}));

const useInboxMock = vi.fn();
vi.mock('dashboard/composables/useInbox', () => ({
  useInbox: (...args) => useInboxMock(...args),
}));

vi.mock('shared/helpers/mitt', () => ({
  emitter: { emit: vi.fn() },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) => {
      if (key === 'CONVERSATION.NATIVE_APP_ADVISORY') {
        return `This message was sent from the ${params.platform} native app.`;
      }
      if (key === 'CONVERSATION.SENT_BY') return 'Sent by:';
      if (key === 'CONVERSATION.AUTOMATION_SYSTEM') {
        return 'Automation';
      }
      if (key === 'CAPTAIN.CHAT_AVATARS.COUNCIL_CAPTION') {
        return `Ответ консилиума: ${params.names}`;
      }
      if (key === 'CAPTAIN.CHAT_AVATARS.MORE') return `+${params.count}`;
      return key;
    },
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({
    query: {},
  }),
}));

vi.mock('shared/helpers/localStorage', () => ({
  LocalStorage: { updateJsonStore: vi.fn() },
}));

vi.mock('shared/composables/useBranding', () => ({
  useBranding: () => ({
    replaceInstallationName: value => value,
  }),
}));

const contextMenuStub = {
  name: 'ContextMenu',
  props: ['enabledOptions', 'message', 'isOpen', 'contextMenuPosition'],
  template: '<div />',
};

const createWrapper = (customProps, stubOverrides = {}) =>
  shallowMount(Message, {
    props: {
      id: 10,
      messageType: MESSAGE_TYPES.OUTGOING,
      status: MESSAGE_STATUS.SENT,
      content: 'test message',
      contentAttributes: {},
      contentType: 'text',
      attachments: [],
      conversationId: 20,
      createdAt: Math.floor(Date.now() / 1000),
      currentUserId: 1,
      inboxId: 30,
      inboxSupportsReplyTo: { outgoing: true },
      additionalAttributes: {},
      sender: null,
      senderId: null,
      senderType: null,
      sourceId: '123',
      ...customProps,
    },
    global: {
      directives: {
        tooltip: (el, binding) => {
          el.setAttribute('data-tooltip', binding.value);
        },
      },
      stubs: {
        Avatar: true,
        TextBubble: { template: '<div />' },
        ActivityBubble: { template: '<div />' },
        ImageBubble: { template: '<div />' },
        FileBubble: { template: '<div />' },
        AudioBubble: { template: '<div />' },
        VideoBubble: { template: '<div />' },
        EmbedBubble: { template: '<div />' },
        InstagramStoryBubble: { template: '<div />' },
        EmailBubble: { template: '<div />' },
        UnsupportedBubble: {
          name: 'UnsupportedBubble',
          template: '<div data-test-id="unsupported-bubble" />',
        },
        ContactBubble: { template: '<div />' },
        DyteBubble: { template: '<div />' },
        LocationBubble: { template: '<div />' },
        CSATBubble: { template: '<div />' },
        FormBubble: { template: '<div />' },
        VoiceCallBubble: { template: '<div />' },
        MessageError: true,
        ContextMenu: contextMenuStub,
        ...stubOverrides,
      },
    },
  });

const captainSender = (overrides = {}) => ({
  id: 18,
  type: 'captain_assistant',
  name: 'Айгерим Ассистент',
  avatarUrl: 'https://cdn.test/agent.png',
  ...overrides,
});

const captainProps = (senderOverrides = {}, customProps = {}) => ({
  sender: captainSender(senderOverrides),
  senderId: 18,
  senderType: 'captain_assistant',
  ...customProps,
});

const councilList = [
  { id: 1, name: 'A', avatarUrl: 'https://cdn.test/a.png' },
  { id: 2, name: 'B' },
  { id: 3, name: 'C' },
  { id: 4, name: 'D' },
];

const gridClasses = wrapper => wrapper.find('.gap-x-2').classes();

describe('Message', () => {
  beforeEach(() => {
    useMapGetterMock.mockReturnValue(
      ref(() => ({ channel_type: 'Channel::Api' }))
    );
    useInboxMock.mockReturnValue({
      isAWhatsAppWebChannel: ref(false),
      isATelegramChannel: ref(false),
      isATelegramPersonalChannel: ref(false),
    });
  });

  it('enables edit and delete for Telegram Personal outgoing provider messages', () => {
    useInboxMock.mockReturnValue({
      isAWhatsAppWebChannel: ref(false),
      isATelegramChannel: ref(false),
      isATelegramPersonalChannel: ref(true),
    });

    const wrapper = createWrapper();
    const contextMenu = wrapper.findComponent({ name: 'ContextMenu' });

    expect(contextMenu.props('enabledOptions').edit).toBe(true);
    expect(contextMenu.props('enabledOptions').delete).toBe(true);
  });

  it('disables edit and delete for Telegram Personal incoming messages', () => {
    useInboxMock.mockReturnValue({
      isAWhatsAppWebChannel: ref(false),
      isATelegramChannel: ref(false),
      isATelegramPersonalChannel: ref(true),
    });

    const wrapper = createWrapper({
      messageType: MESSAGE_TYPES.INCOMING,
    });
    const contextMenu = wrapper.findComponent({ name: 'ContextMenu' });

    expect(contextMenu.props('enabledOptions').edit).toBe(false);
    expect(contextMenu.props('enabledOptions').delete).toBe(false);
  });

  it('keeps WhatsApp Web edit window restriction intact', () => {
    useInboxMock.mockReturnValue({
      isAWhatsAppWebChannel: ref(true),
      isATelegramChannel: ref(false),
      isATelegramPersonalChannel: ref(false),
    });

    const wrapper = createWrapper({
      createdAt: Math.floor(Date.now() / 1000) - 16 * 60,
    });
    const contextMenu = wrapper.findComponent({ name: 'ContextMenu' });

    expect(contextMenu.props('enabledOptions').edit).toBe(false);
  });

  it('renders unsupported messages even when message content is blank', () => {
    const wrapper = createWrapper({
      content: '',
      contentAttributes: { isUnsupported: true },
    });

    expect(wrapper.find('[data-test-id="unsupported-bubble"]').exists()).toBe(
      true
    );
  });

  it('adds the platform name to external echo native app advisory', () => {
    useMapGetterMock.mockReturnValue(
      ref(() => ({
        channel_type: 'Channel::WhatsappWeb',
        medium: null,
      }))
    );

    const wrapper = createWrapper({
      contentAttributes: { externalEcho: true },
    });

    expect(wrapper.find('[data-tooltip]').attributes('data-tooltip')).toBe(
      'This message was sent from the INBOX_MGMT.CHANNELS.WHATSAPP_WEB native app.'
    );
  });

  it('shows a colored channel icon avatar for incoming messages', () => {
    useMapGetterMock.mockReturnValue(
      ref(() => ({
        channel_type: 'Channel::Voice',
        medium: null,
      }))
    );

    const wrapper = createWrapper({
      messageType: MESSAGE_TYPES.INCOMING,
      sender: { id: 2, type: 'Contact', name: 'Client', thumbnail: '' },
      senderId: 2,
      senderType: 'Contact',
    });

    expect(wrapper.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      name: '',
      src: '',
      iconName: 'i-woot-voice',
    });
  });

  it('shows the automation sender and bot background for touch messages', () => {
    const wrapper = createWrapper({
      additionalAttributes: {
        automationRuleId: 24,
        touchId: 143,
        touchOrigin: 'automation',
        touchSource: 'touch',
      },
      sender: {
        id: 1851,
        type: 'User',
        name: 'Akhan Bakhitov',
        thumbnail: '',
      },
      senderId: 1851,
      senderType: 'User',
    });

    expect(wrapper.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      name: 'Automation',
      src: '',
      iconName: 'i-lucide-workflow',
    });
    expect(wrapper.find('[data-tooltip]').attributes('data-tooltip')).toBe(
      'Sent by: Automation'
    );
    expect(wrapper.vm.variant).toBe('bot');
  });

  it('keeps the AI sender identity for AI-generated automation touches', () => {
    const wrapper = createWrapper({
      additionalAttributes: {
        automationRuleId: 24,
        touchId: 143,
        touchOrigin: 'automation',
        touchSource: 'touch',
      },
      sender: {
        id: 18,
        type: 'captain_assistant',
        name: 'AI Sales Manager',
        avatarUrl: 'https://example.com/ai-avatar.png',
      },
      senderId: 18,
      senderType: 'captain_assistant',
    });

    expect(wrapper.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      name: 'AI Sales Manager',
      src: 'https://example.com/ai-avatar.png',
      iconName: null,
    });
    expect(wrapper.vm.variant).toBe('bot');
  });

  it('keeps the employee sender for a manual scheduled touch', () => {
    const wrapper = createWrapper({
      additionalAttributes: { touchId: 143, touchSource: 'touch' },
      sender: {
        id: 1851,
        type: 'User',
        name: 'Akhan Bakhitov',
        thumbnail: '',
      },
      senderId: 1851,
      senderType: 'User',
    });

    expect(wrapper.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      name: 'Akhan Bakhitov',
      src: '',
      iconName: null,
    });
  });

  it('shows the AI agent photo and name for a Captain reply', () => {
    const wrapper = createWrapper(captainProps());

    expect(wrapper.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      name: 'Айгерим Ассистент',
      src: 'https://cdn.test/agent.png',
      iconName: null,
    });
    expect(wrapper.find('[data-tooltip]').attributes('data-tooltip')).toBe(
      'Sent by: Айгерим Ассистент'
    );
    expect(
      wrapper.findComponent({ name: 'CaptainSenderAvatars' }).exists()
    ).toBe(false);
    expect(gridClasses(wrapper)).toContain('grid-cols-[minmax(0,1fr)_24px]');
  });

  it('shows the Captain icon colored by name for an AI agent without a photo', () => {
    const wrapper = createWrapper(captainProps({ avatarUrl: '' }));

    expect(wrapper.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      name: 'Айгерим Ассистент',
      src: '',
      iconName: 'i-woot-captain',
    });
  });

  it('recognises the AI agent by the message sender type', () => {
    const wrapper = createWrapper({
      sender: { id: 18, name: 'Sales AI' },
      senderId: 18,
      senderType: 'Captain::Assistant',
    });

    expect(wrapper.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      name: 'Sales AI',
      src: '',
      iconName: 'i-woot-captain',
    });
  });

  it('keeps the Captain icon only for an AI agent without a name', () => {
    const wrapper = createWrapper(captainProps({ name: '', avatarUrl: '' }));

    expect(wrapper.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      name: '',
      src: '',
      iconName: 'i-woot-captain',
    });
  });

  it('keeps the agent bot avatar behaviour', () => {
    const noPhoto = createWrapper({
      sender: { id: 3, type: 'agent_bot', name: 'Webhook bot' },
      senderId: 3,
      senderType: 'agent_bot',
    });
    const photo = createWrapper({
      sender: {
        id: 3,
        type: 'agent_bot',
        name: 'Webhook bot',
        avatarUrl: 'https://cdn.test/bot.png',
      },
      senderId: 3,
      senderType: 'agent_bot',
    });

    expect(noPhoto.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      name: '',
      src: '',
      iconName: 'i-woot-captain',
    });
    expect(photo.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      name: 'Webhook bot',
      src: 'https://cdn.test/bot.png',
      iconName: null,
    });
  });

  it('shows three stacked avatars, +1 and the council caption for a council reply', () => {
    const wrapper = createWrapper(
      captainProps(
        {},
        { contentAttributes: { councilContributors: councilList } }
      ),
      { CaptainSenderAvatars: false }
    );
    const council = wrapper.findComponent({ name: 'CaptainSenderAvatars' });
    const avatars = council.findAllComponents({ name: 'Avatar' });

    expect(council.exists()).toBe(true);
    expect(council.props('contributors').map(member => member.name)).toEqual([
      'A',
      'B',
      'C',
      'D',
    ]);
    expect(avatars).toHaveLength(3);
    expect(avatars[0].props()).toMatchObject({
      name: 'A',
      src: 'https://cdn.test/a.png',
    });
    expect(avatars[1].props()).toMatchObject({ name: 'B', src: '' });
    expect(
      council.find('[data-testid="captain-sender-avatars-more"]').text()
    ).toBe('+1');
    expect(wrapper.find('[data-tooltip]').attributes('data-tooltip')).toBe(
      'Ответ консилиума: A, B, C, D'
    );
    expect(gridClasses(wrapper)).toContain('grid-cols-[minmax(0,1fr)_auto]');
  });

  it('reads snake_case council contributors from additional attributes', () => {
    const wrapper = createWrapper(
      captainProps(
        {},
        {
          additionalAttributes: {
            council_contributors: [
              { id: 1, name: 'Терапевт', avatar_url: 'https://cdn.test/t.png' },
              { id: 2, name: 'Хирург' },
            ],
          },
        }
      )
    );

    expect(
      wrapper.findComponent({ name: 'CaptainSenderAvatars' }).props()
    ).toMatchObject({
      contributors: [
        { id: 1, name: 'Терапевт', avatarUrl: 'https://cdn.test/t.png' },
        { id: 2, name: 'Хирург', avatarUrl: '' },
      ],
      size: 24,
    });
    expect(wrapper.findComponent({ name: 'Avatar' }).exists()).toBe(false);
    expect(wrapper.find('[data-tooltip]').attributes('data-tooltip')).toBe(
      'Ответ консилиума: Терапевт, Хирург'
    );
  });

  it('keeps the regular avatar column when a council reply is grouped with the next message', () => {
    const wrapper = createWrapper(
      captainProps(
        {},
        {
          groupWithNext: true,
          contentAttributes: { councilContributors: councilList },
        }
      )
    );

    expect(
      wrapper.findComponent({ name: 'CaptainSenderAvatars' }).exists()
    ).toBe(false);
    expect(gridClasses(wrapper)).toContain('grid-cols-[minmax(0,1fr)_24px]');
  });

  it('leaves employee and customer messages unchanged', () => {
    const employee = createWrapper({
      sender: { id: 5, type: 'user', name: 'Akhan Bakhitov', thumbnail: '' },
      senderId: 5,
      senderType: 'User',
    });
    const customer = createWrapper({
      messageType: MESSAGE_TYPES.INCOMING,
      sender: { id: 2, type: 'contact', name: 'Client', thumbnail: '' },
      senderId: 2,
      senderType: 'Contact',
      contentAttributes: { councilContributors: councilList },
    });

    expect(
      employee.findComponent({ name: 'CaptainSenderAvatars' }).exists()
    ).toBe(false);
    expect(employee.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      name: 'Akhan Bakhitov',
      src: '',
    });
    expect(gridClasses(employee)).toContain('grid-cols-[minmax(0,1fr)_24px]');
    expect(
      customer.findComponent({ name: 'CaptainSenderAvatars' }).exists()
    ).toBe(false);
    expect(gridClasses(customer)).toContain('grid-cols-[24px_minmax(0,1fr)]');
  });
});
