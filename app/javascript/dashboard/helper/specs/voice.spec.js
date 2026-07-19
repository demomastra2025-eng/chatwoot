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
            provider: 'sipuni',
            from_number: 'client-party',
            to_number: '+770****4321',
            meta: {
              operator_claim: { user_id: 99, user_name: 'Ayan' },
            },
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
        fromNumber: 'client-party',
        inboxId: 42,
        isActive: false,
        operatorClaim: { user_id: 99, user_name: 'Ayan' },
        provider: 'sipuni',
        senderId: 7,
        toNumber: '+770****4321',
      }),
    ]);
  });

  it('hides a foreign claimed voice call message when observer visibility is disabled', () => {
    handleVoiceCallCreated(
      {
        content_type: 'voice_call',
        conversation_id: 19,
        inbox_id: 42,
        sender: { id: 7 },
        content_attributes: {
          data: {
            call_sid: 'foreign-created-message',
            call_direction: 'inbound',
            provider: 'sipuni',
            status: 'in_progress',
            logical_call_key: 'native-sip:foreign-created-message',
            operator_claim: { user_id: 12, user_name: 'Ayan' },
            show_calls_handled_by_other_operators: false,
          },
        },
      },
      99
    );

    expect(useCallsStore().calls).toEqual([]);
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
            provider: 'sipuni',
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
            provider: 'sipuni',
            status: 'completed',
          },
        },
      },
      99
    );

    expect(callsStore.calls).toEqual([]);
  });

  it('keeps a scoped active native SIP branch on an underscoped terminal message update', () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'shared-terminal-message-sid',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 42,
      logicalCallKey: 'native-sip:shared-terminal-message',
      sipProfileId: 79,
      janusSessionKey: 'sip_profile:79',
      status: 'in_progress',
    });
    callsStore.setCallActive('shared-terminal-message-sid', 'sipuni', {
      sipProfileId: 79,
      janusSessionKey: 'sip_profile:79',
    });

    handleVoiceCallUpdated(
      vi.fn(),
      {
        content_type: 'voice_call',
        conversation_id: 19,
        inbox_id: 42,
        sender: { id: 7 },
        content_attributes: {
          data: {
            call_sid: 'shared-terminal-message-sid',
            call_direction: 'inbound',
            provider: 'sipuni',
            status: 'completed',
            logical_call_key: 'native-sip:shared-terminal-message',
          },
        },
      },
      99
    );

    expect(callsStore.calls).toEqual([
      expect.objectContaining({
        callSid: 'shared-terminal-message-sid',
        isActive: true,
        janusSessionKey: 'sip_profile:79',
      }),
    ]);
    expect(endClientCallMock).not.toHaveBeenCalled();
  });

  it('ends a scoped active branch when the message marks the logical call terminal', async () => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: 'canonical-terminal-message-sid',
      provider: 'sipuni',
      callDirection: 'inbound',
      inboxId: 42,
      logicalCallKey: 'native-sip:canonical-terminal-message',
      sipProfileId: 79,
      janusSessionKey: 'sip_profile:79',
      status: 'in_progress',
    });
    callsStore.setCallActive('canonical-terminal-message-sid', 'sipuni', {
      sipProfileId: 79,
      janusSessionKey: 'sip_profile:79',
    });

    handleVoiceCallUpdated(
      vi.fn(),
      {
        content_type: 'voice_call',
        conversation_id: 19,
        inbox_id: 42,
        sender: { id: 7 },
        content_attributes: {
          data: {
            call_sid: 'canonical-terminal-message-sid',
            call_direction: 'inbound',
            provider: 'sipuni',
            status: 'completed',
            logical_call_key: 'native-sip:canonical-terminal-message',
            logical_call_terminal: true,
          },
        },
      },
      99
    );

    expect(callsStore.calls).toEqual([]);
    await vi.waitFor(() => {
      expect(endClientCallMock).toHaveBeenCalledTimes(1);
    });
  });

  it('hides foreign claimed message updates when observer visibility is disabled', () => {
    handleVoiceCallUpdated(
      vi.fn(),
      {
        content_type: 'voice_call',
        conversation_id: 19,
        inbox_id: 42,
        sender: { id: 7 },
        content_attributes: {
          data: {
            call_sid: 'foreign-claimed-message',
            call_direction: 'inbound',
            provider: 'sipuni',
            status: 'in_progress',
            logical_call_key: 'native-sip:foreign-claimed-message',
            operator_claim: { user_id: 12, user_name: 'Ayan' },
            show_calls_handled_by_other_operators: false,
          },
        },
      },
      99
    );

    expect(useCallsStore().calls).toEqual([]);
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
              provider: 'sipuni',
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

    expect(commit).toHaveBeenCalledWith(
      'UPDATE_CONVERSATION_CALL_STATUS',
      expect.objectContaining({
        callSid: 'call-456',
        callStatus: 'ringing',
        conversationId: 33,
      })
    );
    expect(commit).toHaveBeenCalledWith(
      'UPDATE_MESSAGE_CALL_STATUS',
      expect.objectContaining({
        callSid: 'call-456',
        callStatus: 'ringing',
        conversationId: 33,
      })
    );
    expect(callsStore.calls[0]).toEqual(
      expect.objectContaining({
        callEvent: 'dial_status',
        callLeg: 'callee',
        callSid: 'call-456',
        inboxId: 77,
        provider: 'sipuni',
        rawStatus: 'RINGING',
        status: 'ringing',
      })
    );
  });

  it('restores an outbound Janus SIP active call when an in-progress update arrives first', () => {
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
            call_sid: 'outbound-sipuni-1',
            call_direction: 'outbound',
            provider: 'sipuni',
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
        callSid: 'outbound-sipuni-1',
        conversationId: 44,
        inboxId: 88,
        isActive: true,
        provider: 'sipuni',
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
            call_sid: 'outbound-sipuni-answered',
            call_direction: 'outbound',
            provider: 'sipuni',
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
