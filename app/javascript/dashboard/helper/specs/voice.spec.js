import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

const { endClientCallMock } = vi.hoisted(() => ({
  endClientCallMock: vi.fn(),
}));

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: {
    endClientCall: endClientCallMock,
  },
}));

import { useCallsStore } from 'dashboard/stores/calls';
import { handleVoiceCallCreated, handleVoiceCallUpdated } from '../voice';

describe('voice helper', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    endClientCallMock.mockReset();
  });

  it('adds inbox and provider details from voice call messages', () => {
    handleVoiceCallCreated(
      {
        content_type: 'voice_call',
        conversation_id: 19,
        inbox_id: 42,
        sender: { id: 7 },
        content_attributes: {
          data: {
            call_sid: 'call-123',
            call_direction: 'inbound',
            provider: 'fonoster',
          },
        },
      },
      99
    );

    const callsStore = useCallsStore();

    expect(callsStore.calls).toEqual([
      expect.objectContaining({
        browserJoinSupported: null,
        callDirection: 'inbound',
        callSid: 'call-123',
        conversationId: 19,
        inboxId: 42,
        isActive: false,
        provider: 'fonoster',
        senderId: 7,
      }),
    ]);
  });

  it('resolves inbox details from metadata when a ringing update creates the call', () => {
    const commit = vi.fn();

    handleVoiceCallUpdated(
      commit,
      {
        content_type: 'voice_call',
        conversation_id: 33,
        sender: { id: 11 },
        content_attributes: {
          data: {
            call_sid: 'call-456',
            call_direction: 'inbound',
            status: 'ringing',
            meta: {
              chatwoot_inbox_id: 77,
              provider: 'fonoster',
            },
          },
        },
      },
      11
    );

    const callsStore = useCallsStore();

    expect(commit).toHaveBeenCalledWith('UPDATE_CONVERSATION_CALL_STATUS', {
      callStatus: 'ringing',
      conversationId: 33,
    });
    expect(commit).toHaveBeenCalledWith('UPDATE_MESSAGE_CALL_STATUS', {
      callStatus: 'ringing',
      conversationId: 33,
    });
    expect(callsStore.calls[0]).toEqual(
      expect.objectContaining({
        callSid: 'call-456',
        inboxId: 77,
        provider: 'fonoster',
      })
    );
  });
});
