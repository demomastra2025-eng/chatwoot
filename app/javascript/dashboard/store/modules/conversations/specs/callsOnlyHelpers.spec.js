import { describe, expect, it } from 'vitest';
import {
  applyPageFilters,
  conversationHasCalls,
  filterByCallsOnly,
} from '../helpers';

describe('Calls-only conversation store helpers', () => {
  describe('#conversationHasCalls', () => {
    it('returns true when server serialized has_calls=true', () => {
      expect(conversationHasCalls({ id: 1, has_calls: true })).toBe(true);
    });

    it('returns true for Channel::Voice conversations and multi-channel threads with Channel::Voice', () => {
      expect(
        conversationHasCalls({
          id: 2,
          meta: { channel: 'Channel::Voice' },
        })
      ).toBe(true);

      expect(
        conversationHasCalls({
          id: 3,
          channels: [
            { channel: 'Channel::Whatsapp' },
            { channel: 'Channel::Voice' },
          ],
        })
      ).toBe(true);
    });

    it('returns true for WhatsApp Web call attributes or voice_call messages', () => {
      expect(
        conversationHasCalls({
          id: 4,
          additional_attributes: { call_status: 'ringing' },
        })
      ).toBe(true);

      expect(
        conversationHasCalls({
          id: 5,
          last_non_activity_message: { content_type: 'voice_call' },
        })
      ).toBe(true);

      expect(
        conversationHasCalls({
          id: 6,
          messages: [{ id: 10, content_type: 'voice_call' }],
        })
      ).toBe(true);
    });

    it('returns false for text-only conversations without call markers', () => {
      expect(
        conversationHasCalls({
          id: 7,
          has_calls: false,
          meta: { channel: 'Channel::Whatsapp' },
          additional_attributes: { browser_language: 'ru' },
          messages: [{ id: 11, content_type: 'text' }],
        })
      ).toBe(false);
    });

    it('promotes a conversation initially loaded with has_calls=false when a live call message or call_status arrives', () => {
      expect(
        conversationHasCalls({
          id: 8,
          has_calls: false,
          meta: { channel: 'Channel::Whatsapp' },
          messages: [{ id: 99, content_type: 'voice_call' }],
        })
      ).toBe(true);

      expect(
        conversationHasCalls({
          id: 9,
          has_calls: false,
          meta: { channel: 'Channel::Whatsapp' },
          additional_attributes: { call_status: 'ringing' },
        })
      ).toBe(true);
    });

    it('respects authoritative has_calls=false on communication threads', () => {
      expect(
        conversationHasCalls({
          id: 10,
          is_communication_thread: true,
          has_calls: false,
          channels: [{ channel: 'Channel::Whatsapp' }],
        })
      ).toBe(false);
    });
  });

  describe('#filterByCallsOnly and #applyPageFilters', () => {
    const callConversation = {
      id: 101,
      status: 'open',
      inbox_id: 5,
      has_calls: true,
      labels: [],
    };
    const textConversation = {
      id: 102,
      status: 'open',
      inbox_id: 5,
      has_calls: false,
      labels: [],
    };

    it('filters out text-only conversations when callsOnly is truthy and keeps all when inactive', () => {
      expect(filterByCallsOnly(true, true, callConversation)).toBe(true);
      expect(filterByCallsOnly(true, 'true', textConversation)).toBe(false);
      expect(filterByCallsOnly(true, undefined, textConversation)).toBe(true);
      expect(filterByCallsOnly(true, false, textConversation)).toBe(true);
    });

    it('integrates callsOnly and calls_only into applyPageFilters', () => {
      expect(
        applyPageFilters(callConversation, {
          status: 'open',
          callsOnly: true,
        })
      ).toBe(true);

      expect(
        applyPageFilters(textConversation, {
          status: 'open',
          callsOnly: true,
        })
      ).toBe(false);

      expect(
        applyPageFilters(textConversation, {
          status: 'open',
          calls_only: 'true',
        })
      ).toBe(false);

      expect(
        applyPageFilters(textConversation, {
          status: 'open',
          callsOnly: false,
        })
      ).toBe(true);
    });
  });
});
