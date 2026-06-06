import {
  buildCommunicationThreadConversation,
  buildCommunicationChannelFromMessage,
  decoratePayloadWithCommunicationThread,
  getCommunicationReplyChannel,
  isMessageInCommunicationThread,
} from '../communicationThreadHelper';

const whatsappChannel = {
  conversation_id: 11,
  inbox_id: 101,
  inbox_name: 'WhatsApp',
  contact_inbox_id: 1001,
  channel: 'Channel::WhatsappWeb',
  medium: 'whatsapp_web',
  can_reply: true,
  last_activity_at: 100,
  primary: true,
  channel_key: 'conversation:11',
};

const telegramChannel = {
  conversation_id: 22,
  inbox_id: 202,
  inbox_name: 'Telegram',
  contact_inbox_id: 2002,
  channel: 'Channel::Telegram',
  medium: 'telegram',
  can_reply: true,
  last_activity_at: 200,
  primary: false,
  channel_key: 'conversation:22',
};

const emailUnlinkedChannel = {
  conversation_id: null,
  inbox_id: 303,
  inbox_name: 'Email',
  contact_inbox_id: 3003,
  channel: 'Channel::Email',
  medium: 'email',
  can_reply: true,
  last_activity_at: 300,
  primary: false,
  channel_key: 'inbox:303',
};

describe('communicationThreadHelper', () => {
  describe('#getCommunicationReplyChannel', () => {
    it('uses the channel of the latest incoming replyable message by default', () => {
      const chat = {
        channels: [whatsappChannel, telegramChannel],
        messages: [
          { id: 1, conversation_id: 11, message_type: 0, created_at: 10 },
          { id: 2, conversation_id: 22, message_type: 0, created_at: 20 },
        ],
      };

      expect(getCommunicationReplyChannel(chat)).toEqual(telegramChannel);
    });

    it('respects an explicitly selected reply conversation', () => {
      const chat = {
        channels: [whatsappChannel, telegramChannel],
        messages: [
          { id: 1, conversation_id: 22, message_type: 0, created_at: 20 },
        ],
      };

      expect(getCommunicationReplyChannel(chat, 11)).toEqual(whatsappChannel);
    });
  });

  describe('#decoratePayloadWithCommunicationThread', () => {
    it('sends through the selected child conversation and keeps thread id for optimistic UI', () => {
      const chat = {
        id: 7,
        is_communication_thread: true,
        channels: [whatsappChannel, telegramChannel],
      };

      expect(
        decoratePayloadWithCommunicationThread({ conversationId: 22 }, chat)
      ).toEqual({
        conversationId: 22,
        communicationThreadId: 7,
        channelKey: 'conversation:22',
        targetInboxId: 202,
        targetContactInboxId: 2002,
        inbox_id: 202,
        inbox_name: 'Telegram',
        contact_inbox_id: 2002,
        channel: 'Channel::Telegram',
        medium: 'telegram',
      });
    });

    it('keeps selected unlinked inbox routing out of native conversation_id', () => {
      const chat = {
        id: 7,
        is_communication_thread: true,
        channels: [whatsappChannel, emailUnlinkedChannel],
      };

      expect(
        decoratePayloadWithCommunicationThread(
          { message: 'hello' },
          chat,
          'inbox:303'
        )
      ).toEqual({
        message: 'hello',
        communicationThreadId: 7,
        channelKey: 'inbox:303',
        targetInboxId: 303,
        targetContactInboxId: 3003,
        inbox_id: 303,
        inbox_name: 'Email',
        contact_inbox_id: 3003,
        channel: 'Channel::Email',
        medium: 'email',
      });
    });
  });

  describe('#isMessageInCommunicationThread', () => {
    it('matches realtime messages by explicit communication_thread_id before channel cache exists', () => {
      const chat = {
        id: 7,
        is_communication_thread: true,
        conversation_ids: [],
      };
      const message = { communication_thread_id: 7, conversation_id: 99 };

      expect(isMessageInCommunicationThread(chat, message)).toBe(true);
    });

    it('falls back to linked child conversation ids for older message payloads', () => {
      const chat = {
        id: 7,
        is_communication_thread: true,
        conversation_ids: [11, 22],
      };

      expect(
        isMessageInCommunicationThread(chat, { conversation_id: 22 })
      ).toBe(true);
      expect(
        isMessageInCommunicationThread(chat, { conversation_id: 99 })
      ).toBe(false);
    });
  });

  describe('#buildCommunicationChannelFromMessage', () => {
    it('builds a fallback channel entry from realtime message metadata', () => {
      const message = {
        conversation_id: 99,
        inbox_id: 303,
        inbox_name: 'Email',
        channel: 'Channel::Email',
        contact_inbox_id: 404,
        message_type: 0,
        created_at: 300,
      };

      expect(buildCommunicationChannelFromMessage(message)).toMatchObject({
        conversation_id: 99,
        inbox_id: 303,
        inbox_name: 'Email',
        channel: 'Channel::Email',
        contact_inbox_id: 404,
        can_reply: true,
        last_activity_at: 300,
      });
    });
  });

  describe('#buildCommunicationThreadConversation', () => {
    it('normalizes thread payload to a conversation-compatible record', () => {
      const thread = {
        id: 7,
        channels: [whatsappChannel, telegramChannel],
        messages: [
          { id: 1, conversation_id: 22, message_type: 0, created_at: 20 },
        ],
        meta: { sender: { id: 5, name: 'Customer' } },
      };

      expect(buildCommunicationThreadConversation(thread)).toMatchObject({
        id: 7,
        display_id: 7,
        communication_thread_id: 7,
        is_communication_thread: true,
        inbox_id: 202,
        active_reply_channel_conversation_id: 22,
        can_reply: true,
        conversation_ids: [11, 22],
        meta: { sender: { id: 5, name: 'Customer' } },
      });
    });
  });
});
