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

  it('does not add terminal voice call messages as active browser calls', () => {
    handleVoiceCallCreated(
      {
        content_type: 'voice_call',
        conversation_id: 19,
        inbox_id: 42,
        sender: { id: 7 },
        content_attributes: {
          data: {
            call_sid: 'completed-call-123',
            call_direction: 'inbound',
            provider: 'fonoster',
            status: 'completed',
          },
        },
      },
      99
    );

    const callsStore = useCallsStore();

    expect(callsStore.calls).toEqual([]);
  });

  it('removes an existing call when a terminal voice call message is created', () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'completed-call-123',
      callDirection: 'inbound',
    });

    handleVoiceCallCreated(
      {
        content_type: 'voice_call',
        conversation_id: 19,
        inbox_id: 42,
        sender: { id: 7 },
        content_attributes: {
          data: {
            call_sid: 'completed-call-123',
            call_direction: 'inbound',
            provider: 'fonoster',
            status: 'completed',
          },
        },
      },
      99
    );

    expect(callsStore.calls).toEqual([]);
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
              latest_event_type: 'dial_status',
              latest_leg: 'callee',
              latest_raw_status: 'RINGING',
            },
          },
        },
      },
      11
    );

    const callsStore = useCallsStore();

    expect(commit).toHaveBeenCalledWith('UPDATE_CONVERSATION_CALL_STATUS', {
      callSid: 'call-456',
      callStatus: 'ringing',
      conversationId: 33,
    });
    expect(commit).toHaveBeenCalledWith('UPDATE_MESSAGE_CALL_STATUS', {
      callSid: 'call-456',
      callStatus: 'ringing',
      conversationId: 33,
    });
    expect(callsStore.calls[0]).toEqual(
      expect.objectContaining({
        callEvent: 'dial_status',
        callLeg: 'callee',
        callSid: 'call-456',
        inboxId: 77,
        provider: 'fonoster',
        rawStatus: 'RINGING',
        status: 'ringing',
      })
    );
  });

  it('restores an outbound Fonoster active call when an in-progress update arrives first', () => {
    const commit = vi.fn();

    handleVoiceCallUpdated(
      commit,
      {
        content_type: 'voice_call',
        conversation_id: 44,
        inbox_id: 88,
        sender: { id: 7 },
        content_attributes: {
          data: {
            call_sid: 'outbound-fonoster-1',
            call_direction: 'outbound',
            provider: 'fonoster',
            status: 'in_progress',
          },
        },
      },
      7
    );

    const callsStore = useCallsStore();

    expect(callsStore.calls).toEqual([
      expect.objectContaining({
        callDirection: 'outbound',
        callSid: 'outbound-fonoster-1',
        conversationId: 44,
        inboxId: 88,
        isActive: true,
        provider: 'fonoster',
      }),
    ]);
  });

  it('uses latest leg status metadata when raw provider status is absent', () => {
    handleVoiceCallCreated(
      {
        content_type: 'voice_call',
        conversation_id: 55,
        inbox_id: 91,
        sender: { id: 7 },
        content_attributes: {
          data: {
            call_sid: 'outbound-fonoster-answered',
            call_direction: 'outbound',
            provider: 'fonoster',
            status: 'in_progress',
            meta: {
              latest_event_type: 'dial_status',
              latest_leg: 'callee',
              latest_leg_status: 'in_progress',
            },
          },
        },
      },
      7
    );

    const callsStore = useCallsStore();

    expect(callsStore.calls[0]).toEqual(
      expect.objectContaining({
        callEvent: 'dial_status',
        callLeg: 'callee',
        rawStatus: 'in_progress',
      })
    );
  });
});
