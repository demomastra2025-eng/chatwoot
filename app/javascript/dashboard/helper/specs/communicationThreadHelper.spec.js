import {
  buildCommunicationThreadConversation,
  buildCommunicationChannelFromMessage,
  buildCommunicationChannelFromRealtimePayload,
  decoratePayloadWithCommunicationThread,
  filterConversationsByCommunicationThreadMode,
  getCommunicationContactIdentityLabel,
  getCommunicationReplyChannel,
  getCommunicationReplyChannels,
  getCommunicationThreadChannelInboxes,
  getCommunicationThreadTypingTargetIds,
  getUniqueCommunicationChannels,
  isCommunicationVoiceChannel,
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

const olderWhatsappDuplicate = {
  ...whatsappChannel,
  conversation_id: 44,
  can_reply: false,
  can_send_text: false,
  last_activity_at: 50,
  channel_key: 'conversation:44',
};

const disabledApiChannel = {
  conversation_id: 55,
  inbox_id: 505,
  inbox_name: 'API',
  channel: 'Channel::Api',
  can_reply: false,
  can_send_text: false,
  requires_template: false,
  last_activity_at: 500,
  channel_key: 'conversation:55',
};

describe('communicationThreadHelper', () => {
  describe('#filterConversationsByCommunicationThreadMode', () => {
    it('keeps same-id child conversations out of communication thread lists', () => {
      const childConversation = {
        id: 630,
        status: 'open',
        meta: { sender: { id: 1 } },
      };
      const communicationThread = {
        id: 630,
        communication_thread_id: 630,
        is_communication_thread: true,
        status: 'open',
        meta: { sender: { id: 1 } },
      };
      const conversationList = [childConversation, communicationThread];

      expect(
        filterConversationsByCommunicationThreadMode(conversationList, true)
      ).toEqual([communicationThread]);
      expect(
        filterConversationsByCommunicationThreadMode(conversationList, false)
      ).toEqual([childConversation]);
    });
  });

  describe('#getUniqueCommunicationChannels', () => {
    it('keeps distinct linked conversations even when they share an inbox', () => {
      expect(
        getUniqueCommunicationChannels([
          olderWhatsappDuplicate,
          telegramChannel,
          whatsappChannel,
        ])
      ).toEqual([telegramChannel, whatsappChannel, olderWhatsappDuplicate]);
    });

    it('deduplicates repeated snapshots of the same linked conversation', () => {
      expect(
        getUniqueCommunicationChannels([
          { ...whatsappChannel, can_reply: false, last_activity_at: 50 },
          whatsappChannel,
        ])
      ).toEqual([whatsappChannel]);
    });
  });

  describe('#getCommunicationReplyChannels', () => {
    it('keeps only actionable reply channels after inbox deduplication', () => {
      expect(
        getCommunicationReplyChannels([
          olderWhatsappDuplicate,
          disabledApiChannel,
          whatsappChannel,
        ])
      ).toEqual([whatsappChannel]);
    });
  });

  describe('#getCommunicationThreadChannelInboxes', () => {
    it('builds chat-list filter inboxes from actual linked thread channels only', () => {
      expect(
        getCommunicationThreadChannelInboxes([
          {
            id: 7,
            is_communication_thread: true,
            channels: [
              olderWhatsappDuplicate,
              whatsappChannel,
              telegramChannel,
            ],
          },
          {
            id: 8,
            is_communication_thread: true,
            channels: [disabledApiChannel],
          },
          {
            id: 9,
            is_communication_thread: false,
            channels: [emailUnlinkedChannel],
          },
        ])
      ).toEqual([
        {
          id: 505,
          name: 'API',
          channel_type: 'Channel::Api',
          medium: undefined,
        },
        {
          id: 202,
          name: 'Telegram',
          channel_type: 'Channel::Telegram',
          medium: 'telegram',
        },
        {
          id: 101,
          name: 'WhatsApp',
          channel_type: 'Channel::WhatsappWeb',
          medium: 'whatsapp_web',
        },
      ]);
    });

    it('keeps the channel switcher aligned with the active status route', () => {
      expect(
        getCommunicationThreadChannelInboxes(
          [
            {
              id: 7,
              is_communication_thread: true,
              channels: [
                {
                  ...telegramChannel,
                  conversation_id: 44,
                  inbox_id: 404,
                  contact_inbox_id: 4004,
                  status: 'resolved',
                  last_activity_at: 300,
                },
                {
                  ...telegramChannel,
                  status: 'open',
                },
              ],
            },
          ],
          'open'
        )
      ).toEqual([
        {
          id: 202,
          name: 'Telegram',
          channel_type: 'Channel::Telegram',
          medium: 'telegram',
        },
      ]);
    });

    it('disambiguates duplicate channel labels without changing routing ids', () => {
      expect(
        getCommunicationThreadChannelInboxes(
          [
            {
              id: 7,
              is_communication_thread: true,
              channels: [
                { ...telegramChannel, status: 'open' },
                {
                  ...telegramChannel,
                  conversation_id: 33,
                  inbox_id: 203,
                  contact_inbox_id: 2003,
                  status: 'open',
                  channel_key: 'conversation:33',
                },
              ],
            },
          ],
          'open'
        )
      ).toEqual([
        {
          id: 202,
          name: 'Telegram',
          display_name: 'Telegram #202',
          channel_type: 'Channel::Telegram',
          medium: 'telegram',
        },
        {
          id: 203,
          name: 'Telegram',
          display_name: 'Telegram #203',
          channel_type: 'Channel::Telegram',
          medium: 'telegram',
        },
      ]);
    });
  });

  describe('#getCommunicationContactIdentityLabel', () => {
    it('prefers contact channel profile identity over target inbox names', () => {
      expect(
        getCommunicationContactIdentityLabel({
          inbox_name: 'Business Telegram',
          source_id: 'telegram-target',
          channel_profile: { username: 'client_login' },
        })
      ).toBe('client_login');
    });

    it('falls back to contact inbox source id when no profile identity exists', () => {
      expect(
        getCommunicationContactIdentityLabel({
          inbox_name: '+77100005175',
          source_id: '+77000008623',
        })
      ).toBe('+77000008623');
    });
  });

  describe('#isCommunicationVoiceChannel', () => {
    it('detects voice channels only', () => {
      expect(isCommunicationVoiceChannel({ channel: 'Channel::Voice' })).toBe(
        true
      );
      expect(isCommunicationVoiceChannel(whatsappChannel)).toBe(false);
      expect(isCommunicationVoiceChannel(null)).toBe(false);
    });
  });

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

    it('maps a selected duplicate child conversation back to the single inbox channel', () => {
      const chat = {
        channels: [whatsappChannel, olderWhatsappDuplicate, telegramChannel],
        messages: [],
      };

      expect(getCommunicationReplyChannel(chat, 44)).toEqual(whatsappChannel);
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

  describe('#getCommunicationThreadTypingTargetIds', () => {
    it('includes the aggregate thread id and linked child conversation ids', () => {
      expect(
        getCommunicationThreadTypingTargetIds({
          id: 7,
          is_communication_thread: true,
          conversation_ids: [11, 22, 11],
        })
      ).toEqual([7, 11, 22]);
    });

    it('keeps direct conversations scoped to their own id', () => {
      expect(getCommunicationThreadTypingTargetIds({ id: 11 })).toEqual([11]);
    });
  });

  describe('#buildCommunicationChannelFromRealtimePayload', () => {
    it('builds a channel entry from a partial thread realtime patch', () => {
      expect(
        buildCommunicationChannelFromRealtimePayload({
          conversation_id: 99,
          inbox_id: 303,
          inbox_name: 'Email',
          channel: 'Channel::Email',
          contact_inbox_id: 404,
          can_reply: true,
          timestamp: 300,
        })
      ).toMatchObject({
        conversation_id: 99,
        inbox_id: 303,
        inbox_name: 'Email',
        channel: 'Channel::Email',
        contact_inbox_id: 404,
        can_reply: true,
        can_send_text: true,
        channel_key: 'conversation:99',
        last_activity_at: 300,
      });
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
        conversation_ids: [22, 11],
        meta: { sender: { id: 5, name: 'Customer' } },
      });
    });
  });
});
