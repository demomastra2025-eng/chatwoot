import { afterEach, describe, expect, it, vi } from 'vitest';

import { LocalStorage } from 'shared/helpers/localStorage';
import ReplyBox from './ReplyBox.vue';

const replyButtonLabel = context =>
  ReplyBox.computed.replyButtonLabel.call({
    isEditorHotKeyEnabled: () => false,
    shortcutKey: '⌘+Enter',
    isCommunicationVoiceReplyAction: false,
    isCommunicationThreadConversation: false,
    activeReplyChannel: null,
    isEditingMessage: false,
    isPrivate: false,
    $t: key =>
      ({
        'CONVERSATION.COMMUNICATION_THREAD.CALL_ACTION': 'Позвонить',
        'CONVERSATION.REPLYBOX.SEND': 'Отправить',
        'CONVERSATION.REPLYBOX.CREATE': 'Заметка',
        'CONVERSATION.UPDATE_MESSAGE': 'Обновить',
      })[key] || key,
    ...context,
  });

describe('ReplyBox', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('keeps the text editor enabled for communication-thread voice channels', () => {
    expect(
      ReplyBox.computed.isEditorDisabled.call({
        isCommunicationVoiceReplyAction: true,
        isAWhatsAppChannel: false,
        isAPIInbox: false,
        isOnPrivateNote: false,
        selectedChannelCanReply: true,
      })
    ).toBe(false);
  });

  it('disables public text send for communication-thread voice channels', () => {
    expect(
      ReplyBox.computed.isReplyButtonDisabled.call({
        isCommunicationVoiceReplyAction: true,
        isEditorDisabled: false,
        isATwitterInbox: false,
        hasAttachments: false,
        hasRecordedAudio: false,
        isMessageEmpty: false,
        isEditingMessageUnchanged: false,
        message: 'Нужно перезвонить клиенту',
        maxLength: 1000,
      })
    ).toBe(true);
  });

  it('does not treat voice channel selection as a call action in private note mode', () => {
    expect(
      ReplyBox.computed.isCommunicationVoiceReplyAction.call({
        isCommunicationThreadConversation: true,
        isOnPrivateNote: true,
        activeReplyChannel: { channel: 'Channel::Voice' },
      })
    ).toBe(false);
  });

  it('keeps private note send enabled when a voice channel is selected', () => {
    expect(
      ReplyBox.computed.isReplyButtonDisabled.call({
        isCommunicationVoiceReplyAction: false,
        isEditorDisabled: false,
        isATwitterInbox: false,
        hasAttachments: false,
        hasRecordedAudio: false,
        isMessageEmpty: false,
        isEditingMessageUnchanged: false,
        message: 'Внутренняя заметка',
        maxLength: 1000,
      })
    ).toBe(false);
  });

  it('does not disable regular voice-channel conversations outside communication threads', () => {
    expect(
      ReplyBox.computed.isEditorDisabled.call({
        isCommunicationVoiceReplyAction: false,
        isAWhatsAppChannel: false,
        isAPIInbox: false,
        isOnPrivateNote: false,
        selectedChannelCanReply: true,
      })
    ).toBe(false);
  });

  it('does not force direct voice-channel conversations into private note mode', () => {
    expect(
      ReplyBox.computed.isPrivate.call({
        selectedChannelCanReply: false,
        isAWhatsAppChannel: false,
        isAPIInbox: false,
        isAVoiceChannel: true,
        isOnPrivateNote: false,
      })
    ).toBe(false);
    expect(
      ReplyBox.computed.isReplyRestricted.call({
        selectedChannelCanReply: false,
        isAWhatsAppChannel: false,
        isAPIInbox: false,
        isAVoiceChannel: true,
      })
    ).toBe(false);
  });

  it('treats communication-thread voice channels as replyable call channels', () => {
    expect(
      ReplyBox.computed.selectedChannelCanReply.call({
        isCommunicationThreadConversation: true,
        activeReplyChannel: {
          channel: 'Channel::Voice',
          can_reply: false,
          disabled: false,
        },
      })
    ).toBe(true);
  });

  it('keeps reply mode when a selected communication-thread voice channel changes', () => {
    const context = {
      isOnPrivateNote: false,
      selectedChannelCanReply: false,
      isAWhatsAppChannel: false,
      isAPIInbox: false,
      isAVoiceChannel: true,
      replyType: 'NOTE',
    };

    ReplyBox.methods.syncReplyModeWithSelectedChannel.call(context);

    expect(context.replyType).toBe('REPLY');
  });

  it('uses the selected child conversation for thread reply actions while keeping the route id synthetic', () => {
    const context = {
      isCommunicationThreadConversation: true,
      activeReplyChannel: { conversation_id: 22 },
      currentChat: { id: 7 },
    };

    expect(ReplyBox.computed.conversationId.call(context)).toBe(22);
    expect(ReplyBox.computed.conversationIdByRoute.call(context)).toBe(7);
  });

  it('uses the selected child conversation id for the reply-to banner state', () => {
    const replyToMessage = {
      id: 501,
      conversation_id: 22,
      content: 'quote me',
    };
    const storageSpy = vi
      .spyOn(LocalStorage, 'getFromJsonStore')
      .mockReturnValue(replyToMessage.id);
    const context = {
      conversationId: 22,
      currentChat: {
        id: 7,
        is_communication_thread: true,
        messages: [replyToMessage],
      },
      inReplyTo: null,
    };

    ReplyBox.methods.fetchAndSetReplyTo.call(context);

    expect(storageSpy).toHaveBeenCalledWith(expect.any(String), 22);
    expect(context.inReplyTo).toEqual(replyToMessage);
  });

  it('uses call text without keyboard shortcut for communication-thread voice channels', () => {
    expect(
      replyButtonLabel({
        isCommunicationVoiceReplyAction: true,
        isCommunicationThreadConversation: true,
        activeReplyChannel: { channel: 'Channel::Voice' },
      })
    ).toBe('Позвонить');
  });

  it('keeps private note text and shortcut when a voice channel is selected', () => {
    expect(
      replyButtonLabel({
        isCommunicationVoiceReplyAction: false,
        isCommunicationThreadConversation: true,
        activeReplyChannel: { channel: 'Channel::Voice' },
        isPrivate: true,
      })
    ).toBe('Заметка (↵)');
  });

  it('keeps send text for non-voice communication-thread channels', () => {
    expect(
      replyButtonLabel({
        isCommunicationThreadConversation: true,
        activeReplyChannel: { channel: 'Channel::WhatsappWeb' },
      })
    ).toBe('Отправить (↵)');
  });

  it('does not expose editor keyboard send events for voice call actions', () => {
    expect(
      ReplyBox.methods.isAValidEvent.call({
        isCommunicationVoiceReplyAction: true,
        showUserMentions: false,
        showMentions: false,
        showCannedMenu: false,
        showVariablesMenu: false,
        isFocused: true,
        isEditorHotKeyEnabled: () => true,
      })
    ).toBe(false);
  });
});
