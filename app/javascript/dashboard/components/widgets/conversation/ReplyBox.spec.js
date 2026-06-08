import { describe, expect, it } from 'vitest';

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
