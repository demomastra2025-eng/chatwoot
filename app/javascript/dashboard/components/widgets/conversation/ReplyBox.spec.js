import { afterEach, describe, expect, it, vi } from 'vitest';

import { LocalStorage } from 'shared/helpers/localStorage';
import {
  clearScheduledMessageDraft,
  consumeScheduledMessageDraft,
} from 'dashboard/composables/useScheduledMessageDraft';
import ReplyBox from './ReplyBox.vue';

const replyButtonLabel = context =>
  ReplyBox.computed.replyButtonLabel.call({
    isEditorHotKeyEnabled: () => false,
    shortcutKey: '⌘+Enter',
    isCommunicationVoiceReplyAction: false,
    isCommunicationCallReplyAction: false,
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
    clearScheduledMessageDraft();
  });

  it('passes the current reply draft into the scheduled message editor context', () => {
    const updateUISettings = vi.fn();
    ReplyBox.methods.openScheduledMessages.call({
      attachedFiles: [
        {
          blobSignedId: 'blob-1',
          resource: { filename: 'quote.pdf', content_type: 'application/pdf' },
        },
      ],
      accountId: 1,
      conversationId: 42,
      selectedReplyConversationId: 42,
      currentChat: { id: 42, is_communication_thread: false },
      maxLength: 1000,
      message: 'Follow up tomorrow',
      updateUISettings,
    });

    expect(
      consumeScheduledMessageDraft({
        accountId: 1,
        conversationId: 42,
        remindableId: 42,
        remindableType: 'Conversation',
      })
    ).toMatchObject({
      body: 'Follow up tomorrow',
      accountId: 1,
      attachments: [
        {
          signed_id: 'blob-1',
          filename: 'quote.pdf',
          content_type: 'application/pdf',
        },
      ],
      conversationId: 42,
      remindableId: 42,
      remindableType: 'Conversation',
    });
    expect(updateUISettings).toHaveBeenCalledWith(
      expect.objectContaining({ is_touch_sidebar_open: true })
    );
  });

  it('uses the active reply conversation id for a communication thread draft', () => {
    ReplyBox.methods.openScheduledMessages.call({
      accountId: 1,
      attachedFiles: [],
      conversationId: 900,
      selectedReplyConversationId: 42,
      currentChat: { id: 700, is_communication_thread: true },
      maxLength: 1000,
      message: 'Thread follow-up',
      updateUISettings: vi.fn(),
    });

    expect(
      consumeScheduledMessageDraft({
        accountId: 1,
        conversationId: 42,
        remindableId: 700,
        remindableType: 'CommunicationThread',
      })
    ).toMatchObject({ body: 'Thread follow-up', conversationId: 42 });
  });

  it('keeps the text editor enabled for communication-thread voice channels', () => {
    expect(
      ReplyBox.computed.isEditorDisabled.call({
        isCommunicationVoiceReplyAction: true,
        isCommunicationCallReplyAction: true,
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
        isCommunicationCallReplyAction: true,
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
        isCommunicationCallReplyAction: false,
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

  it('keeps recorded-audio send disabled until the audio is attached', () => {
    expect(
      ReplyBox.computed.isReplyButtonDisabled.call({
        isCommunicationCallReplyAction: false,
        isEditorDisabled: false,
        isATwitterInbox: false,
        hasAttachments: false,
        hasRecordedAudio: true,
        isMessageEmpty: true,
        isEditingMessageUnchanged: false,
        message: '',
        maxLength: 1000,
      })
    ).toBe(true);

    expect(
      ReplyBox.computed.isReplyButtonDisabled.call({
        isCommunicationCallReplyAction: false,
        isEditorDisabled: false,
        isATwitterInbox: false,
        hasAttachments: 1,
        hasRecordedAudio: true,
        isMessageEmpty: true,
        isEditingMessageUnchanged: false,
        message: '',
        maxLength: 1000,
      })
    ).toBe(false);
  });

  it('does not build an empty WhatsApp text payload when there are no attachments', () => {
    const context = {
      attachedFiles: [],
      isAnInstagramChannel: false,
      isATiktokChannel: false,
      message: '',
      conversationId: 42,
      sender: { name: 'Agent' },
      setReplyToInPayload: payload => payload,
    };

    expect(
      ReplyBox.methods.getMultipleMessagesPayload.call(context, '')
    ).toEqual([]);
  });

  it('keeps the text editor enabled for direct voice-channel conversations', () => {
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

  it('treats direct voice-channel conversations as call actions', () => {
    expect(
      ReplyBox.computed.isCommunicationVoiceReplyAction.call({
        isCommunicationThreadConversation: false,
        isOnPrivateNote: false,
        isAVoiceChannel: true,
        activeReplyChannel: null,
      })
    ).toBe(true);
  });

  it('treats the selected WhatsApp Official call action as a communication-thread call action', () => {
    const activeReplyChannel = {
      channel: 'Channel::Whatsapp',
      communication_action: 'call',
      channel_key: 'conversation:44:action:call',
    };

    expect(
      ReplyBox.computed.isCommunicationCallReplyAction.call({
        isCommunicationThreadConversation: true,
        isOnPrivateNote: false,
        activeReplyChannel,
      })
    ).toBe(true);
    expect(
      replyButtonLabel({
        isCommunicationCallReplyAction: true,
        isCommunicationThreadConversation: true,
        activeReplyChannel,
      })
    ).toBe('Позвонить');
    expect(
      ReplyBox.computed.showFileUpload.call({
        isCommunicationCallReplyAction: true,
      })
    ).toBe(false);
    expect(
      ReplyBox.computed.showWhatsappTemplates.call({
        isCommunicationCallReplyAction: true,
      })
    ).toBe(false);
  });

  it('treats the selected direct WhatsApp Official call action as a call action', () => {
    const directContext = {
      isCommunicationThreadConversation: false,
      isOnPrivateNote: false,
      selectedDirectReplyAction: 'call',
      isAWhatsAppCloudChannel: true,
      inbox: { calling_enabled: true },
    };

    expect(
      ReplyBox.computed.isDirectWhatsappCallReplyAction.call(directContext)
    ).toBe(true);
    expect(
      ReplyBox.computed.isCommunicationCallReplyAction.call({
        ...directContext,
        isDirectWhatsappCallReplyAction: true,
        isAVoiceChannel: false,
      })
    ).toBe(true);
    expect(
      ReplyBox.computed.isEditorDisabled.call({
        isCommunicationCallReplyAction: true,
        isAWhatsAppChannel: true,
        isAPIInbox: false,
        isOnPrivateNote: false,
        selectedChannelCanSendText: false,
      })
    ).toBe(false);
    expect(
      replyButtonLabel({
        isCommunicationCallReplyAction: true,
        isCommunicationThreadConversation: false,
        isAWhatsAppCloudChannel: true,
      })
    ).toBe('Позвонить');
    expect(
      ReplyBox.computed.showFileUpload.call({
        isCommunicationCallReplyAction: true,
      })
    ).toBe(false);
    expect(
      ReplyBox.methods.isAValidEvent.call({
        isCommunicationCallReplyAction: true,
        showUserMentions: false,
        showMentions: false,
        showCannedMenu: false,
        showVariablesMenu: false,
        isFocused: true,
        isEditorHotKeyEnabled: () => true,
      })
    ).toBe(false);
  });

  it('stores the selected direct reply action', () => {
    const context = { selectedDirectReplyAction: 'message' };

    ReplyBox.methods.selectDirectReplyAction.call(context, 'call');
    expect(context.selectedDirectReplyAction).toBe('call');

    ReplyBox.methods.selectDirectReplyAction.call(context);
    expect(context.selectedDirectReplyAction).toBe('message');
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

  it('keeps template-required WhatsApp channels actionable without allowing free-text input', () => {
    const context = {
      isCommunicationThreadConversation: true,
      activeReplyChannel: {
        channel: 'Channel::Whatsapp',
        can_reply: false,
        can_send_text: false,
        requires_template: true,
      },
      isAWhatsAppChannel: true,
      isAPIInbox: false,
      isOnPrivateNote: false,
    };

    context.selectedChannelCanReply =
      ReplyBox.computed.selectedChannelCanReply.call(context);
    context.selectedChannelCanSendText =
      ReplyBox.computed.selectedChannelCanSendText.call(context);

    expect(context.selectedChannelCanReply).toBe(true);
    expect(context.selectedChannelCanSendText).toBe(false);
    expect(ReplyBox.computed.isEditorDisabled.call(context)).toBe(true);
    expect(
      ReplyBox.computed.showWhatsappTemplates.call({
        inboxId: 143,
        isPrivate: false,
        $store: {
          getters: {
            'inboxes/getFilteredWhatsAppTemplates': inboxId =>
              inboxId === 143 ? [{ name: 'approved_template' }] : [],
          },
        },
      })
    ).toBe(true);
  });

  it('keeps WhatsApp text input enabled when the selected thread channel can send text', () => {
    const context = {
      isCommunicationThreadConversation: true,
      activeReplyChannel: {
        channel: 'Channel::Whatsapp',
        can_reply: true,
        can_send_text: true,
        requires_template: false,
      },
      isAWhatsAppChannel: true,
      isAPIInbox: false,
      isOnPrivateNote: false,
    };

    context.selectedChannelCanReply =
      ReplyBox.computed.selectedChannelCanReply.call(context);
    context.selectedChannelCanSendText =
      ReplyBox.computed.selectedChannelCanSendText.call(context);

    expect(context.selectedChannelCanReply).toBe(true);
    expect(context.selectedChannelCanSendText).toBe(true);
    expect(ReplyBox.computed.isEditorDisabled.call(context)).toBe(false);
  });

  it('falls back to the cached active reply channel when thread channels are not hydrated yet', () => {
    const activeReplyChannel = {
      conversation_id: 22,
      inbox_id: 154,
      channel: 'Channel::Whatsapp',
    };
    const context = {
      currentChat: {
        is_communication_thread: true,
        channels: [],
        active_reply_channel: activeReplyChannel,
      },
      selectedReplyConversationId: null,
    };

    expect(ReplyBox.computed.activeReplyChannel.call(context)).toEqual(
      activeReplyChannel
    );
  });

  it('uses cached thread inbox id for templates when active reply channel is not available', () => {
    expect(
      ReplyBox.computed.inboxId.call({
        isCommunicationThreadConversation: true,
        activeReplyChannel: null,
        currentChat: {
          active_reply_channel_inbox_id: 154,
          inbox_id: 155,
        },
      })
    ).toBe(154);
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
        isCommunicationCallReplyAction: true,
        isCommunicationThreadConversation: true,
        activeReplyChannel: { channel: 'Channel::Voice' },
      })
    ).toBe('Позвонить');
  });

  it('uses call text without keyboard shortcut for direct voice-channel conversations', () => {
    expect(
      replyButtonLabel({
        isCommunicationVoiceReplyAction: true,
        isCommunicationCallReplyAction: true,
        isCommunicationThreadConversation: false,
        isAVoiceChannel: true,
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
        isCommunicationCallReplyAction: true,
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
