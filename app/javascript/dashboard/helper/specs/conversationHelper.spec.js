import {
  filterDuplicateSourceMessages,
  getLastMessage,
  getReadMessages,
  getUnreadIncomingMessages,
  getUnreadMessages,
  isImportedHistoryMessage,
} from '../conversationHelper';
import {
  conversationData,
  lastMessageData,
  readMessagesData,
  unReadMessagesData,
} from './fixtures/conversationFixtures';

describe('conversationHelper', () => {
  describe('#filterDuplicateSourceMessages', () => {
    it('returns messages without duplicate source_id and all messages without source_id', () => {
      const input = [
        { source_id: null, id: 1 },
        { source_id: '', id: 2 },
        { id: 3 },
        { source_id: 'wa_1', id: 4 },
        { source_id: 'wa_1', id: 5 },
        { source_id: 'wa_1', id: 6 },
        { source_id: 'wa_2', id: 7 },
        { source_id: 'wa_2', id: 8 },
        { source_id: 'wa_3', id: 9 },
      ];
      const expected = [
        { source_id: null, id: 1 },
        { source_id: '', id: 2 },
        { id: 3 },
        { source_id: 'wa_1', id: 4 },
        { source_id: 'wa_2', id: 7 },
        { source_id: 'wa_3', id: 9 },
      ];
      expect(filterDuplicateSourceMessages(input)).toEqual(expected);
    });
  });

  describe('#readMessages', () => {
    it('should return read messages if conversation is passed', () => {
      expect(
        getReadMessages(
          conversationData.messages,
          conversationData.agent_last_seen_at
        )
      ).toEqual(readMessagesData);
    });
  });

  describe('#unReadMessages', () => {
    it('should return unread messages if conversation is passed', () => {
      expect(
        getUnreadMessages(
          conversationData.messages,
          conversationData.agent_last_seen_at
        )
      ).toEqual(unReadMessagesData);
    });
  });

  describe('#isImportedHistoryMessage', () => {
    it.each([
      [{ imported_history: true }, true],
      [{ imported_history: 'TRUE' }, true],
      ['{"imported_history":true}', true],
      ['{"imported_history":"true"}', true],
      ['{legacy opaque value', false],
      [{ imported_history: false }, false],
      [undefined, false],
    ])(
      'normalizes object and string content attributes',
      (contentAttributes, expected) => {
        expect(
          isImportedHistoryMessage({ content_attributes: contentAttributes })
        ).toBe(expected);
      }
    );
  });

  describe('#getUnreadIncomingMessages', () => {
    it('excludes imported history in object and JSON-string representations', () => {
      const messages = [
        { id: 1, message_type: 0, private: false, created_at: 2 },
        {
          id: 2,
          message_type: 0,
          private: false,
          created_at: 2,
          content_attributes: { imported_history: true },
        },
        {
          id: 3,
          message_type: 0,
          private: false,
          created_at: 2,
          content_attributes: '{"imported_history":"true"}',
        },
      ];

      expect(getUnreadIncomingMessages(messages, 1)).toEqual([messages[0]]);
    });
  });

  describe('#lastMessage', () => {
    it("should return last activity message if both api and store doesn't have other messages", () => {
      const testConversation = {
        messages: [conversationData.messages[0]],
        last_non_activity_message: null,
      };
      expect(getLastMessage(testConversation)).toEqual(
        testConversation.messages[0]
      );
    });

    it('should return message from store if store has latest message', () => {
      const testConversation = {
        messages: [],
        last_non_activity_message: lastMessageData,
      };
      expect(getLastMessage(testConversation)).toEqual(lastMessageData);
    });

    it('should return message from API if list payload does not include messages', () => {
      const testConversation = {
        last_non_activity_message: lastMessageData,
      };
      expect(getLastMessage(testConversation)).toEqual(lastMessageData);
    });

    it('should return last non activity message from store if api value is empty', () => {
      const testConversation = {
        messages: [conversationData.messages[0], conversationData.messages[1]],
        last_non_activity_message: null,
      };
      expect(getLastMessage(testConversation)).toEqual(
        testConversation.messages[1]
      );
    });

    it("should return last non activity message from store if store doesn't have any messages", () => {
      const testConversation = {
        messages: [conversationData.messages[1], conversationData.messages[2]],
        last_non_activity_message: conversationData.messages[0],
      };
      expect(getLastMessage(testConversation)).toEqual(
        testConversation.messages[1]
      );
    });

    it('should return the latest activity message when it is newer than the last chat message', () => {
      const activityMessage = {
        id: 438214,
        content: 'John reopened the conversation',
        message_type: 2,
        created_at: lastMessageData.created_at + 60,
      };
      const testConversation = {
        messages: [activityMessage],
        last_non_activity_message: lastMessageData,
      };
      expect(getLastMessage(testConversation)).toEqual(activityMessage);
    });
  });
});
