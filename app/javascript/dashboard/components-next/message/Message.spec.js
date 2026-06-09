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

const createWrapper = customProps =>
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
      },
    },
  });

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
});
