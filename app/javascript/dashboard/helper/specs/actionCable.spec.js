import { describe, it, beforeEach, afterEach, expect, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import ActionCableConnector from '../actionCable';
import {
  getOutboundCallState,
  useWhatsappCallsStore,
} from 'dashboard/stores/whatsappCalls';
import { useCallsStore } from 'dashboard/stores/calls';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';

const {
  reconnectMock,
  clearPreparedInboundAgentAnswerMock,
  handleAgentOfferMock,
  handleMediaLegClosedMock,
  isMediaLegClosedErrorMock,
  prewarmInboundAgentAnswerForCallMock,
  startCallRecordingMock,
  startFaviconBlinkingMock,
  stopFaviconBlinkingMock,
} = vi.hoisted(() => ({
  reconnectMock: vi.fn(),
  clearPreparedInboundAgentAnswerMock: vi.fn(),
  handleAgentOfferMock: vi.fn(),
  handleMediaLegClosedMock: vi.fn(),
  isMediaLegClosedErrorMock: vi.fn(() => false),
  prewarmInboundAgentAnswerForCallMock: vi.fn(),
  startCallRecordingMock: vi.fn(),
  startFaviconBlinkingMock: vi.fn(),
  stopFaviconBlinkingMock: vi.fn(),
}));

vi.mock('shared/helpers/mitt', () => ({
  emitter: {
    emit: vi.fn(),
  },
}));

vi.mock('dashboard/composables/useImpersonation', () => ({
  useImpersonation: () => ({
    isImpersonating: { value: false },
  }),
}));

vi.mock('dashboard/composables/useWhatsappCallSession', () => ({
  clearPreparedInboundAgentAnswer: clearPreparedInboundAgentAnswerMock,
  handleAgentOffer: handleAgentOfferMock,
  handleMediaLegClosed: handleMediaLegClosedMock,
  isMediaLegClosedError: isMediaLegClosedErrorMock,
  prewarmInboundAgentAnswerForCall: prewarmInboundAgentAnswerForCallMock,
  startCallRecording: startCallRecordingMock,
}));

vi.mock('dashboard/api/whatsappCalls', () => ({
  default: {
    reconnect: reconnectMock,
  },
}));

vi.mock('../AudioAlerts/faviconHelper', () => ({
  initFaviconSwitcher: vi.fn(),
  restoreFavicon: vi.fn(),
  showBadgeOnFavicon: vi.fn(),
  startFaviconBlinking: startFaviconBlinkingMock,
  stopFaviconBlinking: stopFaviconBlinkingMock,
}));

global.chatwootConfig = {
  websocketURL: 'wss://test.one-link.kz',
};

describe('ActionCableConnector - Copilot Tests', () => {
  let store;
  let actionCable;
  let mockDispatch;

  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
    window.localStorage.clear();
    reconnectMock.mockResolvedValue({
      data: { sdp_offer: 'fresh-offer', ice_servers: [] },
    });
    handleAgentOfferMock.mockResolvedValue();
    prewarmInboundAgentAnswerForCallMock.mockReturnValue(null);
    isMediaLegClosedErrorMock.mockReturnValue(false);
    mockDispatch = vi.fn();
    store = {
      $store: {
        dispatch: mockDispatch,
        commit: vi.fn(),
        state: { conversations: { conversationFilters: {} } },
        getters: {
          getCurrentAccountId: 1,
          getCurrentUserID: 7,
        },
      },
    };

    actionCable = ActionCableConnector.init(store.$store, 'test-token');
  });

  afterEach(() => {
    actionCable?.disconnect();
  });

  const sidebarUnreadRefreshCalls = () =>
    mockDispatch.mock.calls.filter(
      ([actionName]) => actionName === 'fetchSidebarUnreadCounts'
    );

  describe('sidebar unread count refreshes', () => {
    it('debounces repeated refreshes from realtime events', async () => {
      vi.useFakeTimers();
      try {
        actionCable.fetchSidebarUnreadCounts();
        actionCable.fetchSidebarUnreadCounts();

        expect(sidebarUnreadRefreshCalls()).toHaveLength(0);

        await vi.advanceTimersByTimeAsync(1000);

        expect(sidebarUnreadRefreshCalls()).toHaveLength(1);
      } finally {
        vi.useRealTimers();
      }
    });

    it('queues one trailing refresh while a count request is in flight', async () => {
      vi.useFakeTimers();
      let resolveRefresh;
      mockDispatch.mockImplementation(actionName => {
        if (actionName !== 'fetchSidebarUnreadCounts') return undefined;

        return new Promise(resolve => {
          resolveRefresh = resolve;
        });
      });

      try {
        actionCable.fetchSidebarUnreadCounts();
        await vi.advanceTimersByTimeAsync(1000);
        expect(sidebarUnreadRefreshCalls()).toHaveLength(1);

        actionCable.fetchSidebarUnreadCounts();
        actionCable.fetchSidebarUnreadCounts();
        expect(sidebarUnreadRefreshCalls()).toHaveLength(1);

        resolveRefresh();
        await Promise.resolve();
        await vi.advanceTimersByTimeAsync(30000);

        expect(sidebarUnreadRefreshCalls()).toHaveLength(2);
      } finally {
        vi.useRealTimers();
      }
    });

    it('does not refresh in a hidden tab and catches up when visible', async () => {
      vi.useFakeTimers();
      const originalVisibilityState = Object.getOwnPropertyDescriptor(
        document,
        'visibilityState'
      );
      try {
        Object.defineProperty(document, 'visibilityState', {
          configurable: true,
          value: 'hidden',
        });
        actionCable.fetchSidebarUnreadCounts();
        await vi.advanceTimersByTimeAsync(10000);
        expect(sidebarUnreadRefreshCalls()).toHaveLength(0);

        Object.defineProperty(document, 'visibilityState', {
          configurable: true,
          value: 'visible',
        });
        document.dispatchEvent(new Event('visibilitychange'));
        await vi.advanceTimersByTimeAsync(1000);
        expect(sidebarUnreadRefreshCalls()).toHaveLength(1);
      } finally {
        if (originalVisibilityState) {
          Object.defineProperty(
            document,
            'visibilityState',
            originalVisibilityState
          );
        } else {
          delete document.visibilityState;
        }
        vi.useRealTimers();
      }
    });

    it('applies unread counts published by another tab', () => {
      const counts = { all: 4, statuses: { open: 4 } };
      const refreshedAt = Date.now();
      actionCable.onSidebarUnreadCountsStorage({
        key: actionCable.sidebarUnreadCountsStorageKey,
        newValue: JSON.stringify({
          contextId: actionCable.sidebarUnreadCountsContextId(),
          counts,
          requestedAt: refreshedAt - 5,
          refreshedAt,
        }),
      });

      expect(store.$store.commit).toHaveBeenCalledWith(
        'SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS',
        counts
      );
      expect(actionCable.lastSidebarUnreadCountsRefreshAt).toBe(refreshedAt);
    });

    it('ignores stale counts from an older request', () => {
      actionCable.lastSidebarUnreadCountsRequestedAt = 200;
      actionCable.lastSidebarUnreadCountsRefreshAt = 300;

      actionCable.onSidebarUnreadCountsStorage({
        key: actionCable.sidebarUnreadCountsStorageKey,
        newValue: JSON.stringify({
          contextId: actionCable.sidebarUnreadCountsContextId(),
          counts: { all: 1 },
          requestedAt: 100,
          refreshedAt: 250,
        }),
      });

      expect(store.$store.commit).not.toHaveBeenCalledWith(
        'SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS',
        { all: 1 }
      );
    });

    it('does not schedule refreshes after disconnect', async () => {
      vi.useFakeTimers();
      try {
        actionCable.disconnect();
        actionCable.fetchSidebarUnreadCounts();
        await vi.advanceTimersByTimeAsync(10000);

        expect(sidebarUnreadRefreshCalls()).toHaveLength(0);
      } finally {
        vi.useRealTimers();
      }
    });

    it('does not duplicate a refresh while another tab owns the browser lock', async () => {
      vi.useFakeTimers();
      const originalLocks = Object.getOwnPropertyDescriptor(navigator, 'locks');
      const request = vi.fn((_name, _options, callback) => callback(null));
      try {
        Object.defineProperty(navigator, 'locks', {
          configurable: true,
          value: { request },
        });

        actionCable.fetchSidebarUnreadCounts();
        await vi.advanceTimersByTimeAsync(1000);

        expect(request).toHaveBeenCalledTimes(1);
        expect(sidebarUnreadRefreshCalls()).toHaveLength(0);
      } finally {
        if (originalLocks) {
          Object.defineProperty(navigator, 'locks', originalLocks);
        } else {
          delete navigator.locks;
        }
        vi.useRealTimers();
      }
    });

    it('does not retry a storage-lock callback after it fails', async () => {
      const callback = vi.fn().mockRejectedValue(new Error('refresh failed'));

      await expect(
        actionCable.runSidebarUnreadCountsWithStorageLock('failure', callback)
      ).rejects.toThrow('refresh failed');

      expect(callback).toHaveBeenCalledTimes(1);
    });
  });

  describe('browser tab notifications', () => {
    const notificationPayload = inboxNotificationEnabled => ({
      account_id: 1,
      inbox_notification_enabled: inboxNotificationEnabled,
      notification: { id: 42, notification_type: 'task_assignment' },
      unread_count: 1,
      count: 1,
    });

    it('starts favicon blinking for inbox-enabled notifications', () => {
      const payload = notificationPayload(true);

      actionCable.onNotificationCreated(payload);

      expect(mockDispatch).toHaveBeenCalledWith(
        'notifications/addNotification',
        payload
      );
      expect(startFaviconBlinkingMock).toHaveBeenCalledTimes(1);
    });

    it.each([false, undefined])(
      'does not blink for disabled or legacy notification payloads (%s)',
      inboxNotificationEnabled => {
        actionCable.onNotificationCreated(
          notificationPayload(inboxNotificationEnabled)
        );

        expect(startFaviconBlinkingMock).not.toHaveBeenCalled();
      }
    );

    it('stops favicon blinking when the websocket disconnects', () => {
      actionCable.onDisconnected();

      expect(stopFaviconBlinkingMock).toHaveBeenCalledTimes(1);
    });
  });

  describe('communication thread realtime events', () => {
    it('registers the communication_thread.updated event handler', () => {
      expect(actionCable.events['communication_thread.updated']).toBe(
        actionCable.onCommunicationThreadUpdated
      );
    });

    it('updates the synthetic thread without requiring conversation meta', () => {
      const payload = {
        id: 7,
        communication_thread_id: 7,
        is_communication_thread: true,
        conversation_ids: [11, 22],
        unread_count: 3,
        timestamp: 1710000000,
        updated_at: 1710000000.25,
        account_id: 1,
      };

      actionCable.onReceived({
        event: 'communication_thread.updated',
        data: payload,
      });

      expect(mockDispatch).toHaveBeenCalledWith(
        'updateCommunicationThreadRealtime',
        payload
      );
      expect(emitter.emit).toHaveBeenCalledWith('fetch_conversation_stats');
    });

    it('avoids the duplicate legacy stats refresh in communication thread mode', () => {
      store.$store.state.conversations.conversationFilters = {
        communicationThreadMode: true,
      };
      const sidebarRefresh = vi.spyOn(actionCable, 'fetchSidebarUnreadCounts');

      actionCable.onCommunicationThreadUpdated({
        id: 7,
        communication_thread_id: 7,
        account_id: 1,
      });

      expect(emitter.emit).not.toHaveBeenCalledWith('fetch_conversation_stats');
      expect(sidebarRefresh).toHaveBeenCalledTimes(1);
    });

    it('updates cached conversation/thread contact identities from contact updates', () => {
      const payload = { account_id: 1, id: 42, name: 'Updated customer' };

      actionCable.onReceived({
        event: 'contact.updated',
        data: payload,
      });

      expect(mockDispatch).toHaveBeenCalledWith(
        'contacts/updateContact',
        payload
      );
      expect(mockDispatch).toHaveBeenCalledWith(
        'updateContactInConversations',
        payload
      );
    });
  });

  describe('copilot event handlers', () => {
    it('should register the copilot.message.created event handler', () => {
      expect(Object.keys(actionCable.events)).toContain(
        'copilot.message.created'
      );
      expect(actionCable.events['copilot.message.created']).toBe(
        actionCable.onCopilotMessageCreated
      );
    });

    it('should handle the copilot.message.created event through the ActionCable system', () => {
      const copilotData = {
        id: 2,
        content: 'This is a copilot message from ActionCable',
        conversation_id: 456,
        created_at: '2025-05-27T15:58:04-06:00',
        account_id: 1,
      };
      actionCable.onReceived({
        event: 'copilot.message.created',
        data: copilotData,
      });
      expect(mockDispatch).toHaveBeenCalledWith(
        'copilotMessages/upsert',
        copilotData
      );
    });
    it('should register WhatsApp agent disconnect handler', () => {
      expect(Object.keys(actionCable.events)).toContain(
        'whatsapp_call.agent_disconnected'
      );
      expect(actionCable.events['whatsapp_call.agent_disconnected']).toBe(
        actionCable.onWhatsappCallAgentDisconnected
      );
    });

    it('stores native voice incoming calls from lightweight realtime events', () => {
      const callsStore = useCallsStore();

      actionCable.onReceived({
        event: 'voice_call.incoming',
        data: {
          account_id: 1,
          call_sid: 'sipuni-inbound-1',
          status: 'ringing',
          call_direction: 'inbound',
          provider: 'sipuni',
          inbox_id: 4593,
          number_ref: 'voice-number-4593',
          logical_call_key: 'sipuni-inbound:shared-key',
          conversation_id: 627,
          conversation_display_id: 627,
          conversation_db_id: 93627,
          communication_thread_id: 72,
          contact_id: 8123,
          caller: { phone_number: '+770****8623' },
          from_number: 'client-party',
          to_number: 'support-line',
          operator_claim: { user_id: 9, user_name: 'Ayan' },
          operator_candidates: [
            { user_id: 9, name: 'Ayan', internal_extension: '502' },
          ],
          operator_internal_extension: '502',
          sip_profile_id: 42,
          janus_call_ref: 'janus-invite-42',
          janus_session_key: 'sip_profile:42',
          sipuni_native_webphone_correlation: true,
          browser_join_supported: true,
        },
      });

      expect(callsStore.incomingCalls[0]).toMatchObject({
        callSid: 'sipuni-inbound-1',
        status: 'ringing',
        callDirection: 'inbound',
        provider: 'sipuni',
        inboxId: 4593,
        numberRef: 'voice-number-4593',
        logicalCallKey: 'sipuni-inbound:shared-key',
        conversationId: 627,
        conversationDbId: 93627,
        communicationThreadId: 72,
        contactId: 8123,
        caller: { phone_number: '+770****8623' },
        fromNumber: 'client-party',
        toNumber: 'support-line',
        operatorClaim: { user_id: 9, user_name: 'Ayan' },
        operatorCandidates: [
          { user_id: 9, name: 'Ayan', internal_extension: '502' },
        ],
        operatorInternalExtension: '502',
        sipProfileId: 42,
        janusCallRef: 'janus-invite-42',
        janusSessionKey: 'sip_profile:42',
        sipuniNativeWebphoneCorrelation: true,
        browserJoinSupported: true,
      });
    });

    it('stores server-managed Janus voice calls as AI-handled outside-browser calls', () => {
      const callsStore = useCallsStore();

      actionCable.onReceived({
        event: 'voice_call.status_changed',
        data: {
          account_id: 1,
          call_sid: 'sipuni:janus-server:49:server-ai-call',
          status: 'in_progress',
          call_direction: 'inbound',
          provider: 'sipuni',
          inbox_id: 4593,
          from_number: '+77000000000',
          to_number: '+77017450000',
          browser_join_supported: false,
          metadata: {
            source: 'server_janus_sip',
            server_runtime: true,
          },
        },
      });

      expect(callsStore.calls).toEqual([
        expect.objectContaining({
          callSid: 'sipuni:janus-server:49:server-ai-call',
          status: 'in_progress',
          browserJoinSupported: false,
          browserJoinUnsupportedReason: 'AI_AGENT_HANDLING',
          serverManagedVoiceCall: true,
        }),
      ]);
    });

    it('keeps normal browser Janus voice calls visible in the operator widget', () => {
      const callsStore = useCallsStore();

      actionCable.onReceived({
        event: 'voice_call.status_changed',
        data: {
          account_id: 1,
          call_sid: 'sipuni:janus:49:operator-call',
          status: 'in_progress',
          call_direction: 'inbound',
          provider: 'sipuni',
          inbox_id: 4593,
          from_number: '+77000000001',
          to_number: '+77017450000',
          browser_join_supported: false,
        },
      });

      expect(callsStore.calls).toEqual([
        expect.objectContaining({
          callSid: 'sipuni:janus:49:operator-call',
          status: 'in_progress',
          browserJoinSupported: false,
        }),
      ]);
    });

    it('emits browser SIP config change events to the dashboard bus', () => {
      actionCable.onReceived({
        event: 'telephony.webphone_config_changed',
        data: {
          account_id: 1,
          provider: 'sipuni',
          inbox_id: 4776,
          sip_profile_ids: [48],
        },
      });

      expect(emitter.emit).toHaveBeenCalledWith(
        BUS_EVENTS.TELEPHONY_WEBPHONE_CONFIG_CHANGED,
        {
          account_id: 1,
          provider: 'sipuni',
          inbox_id: 4776,
          sip_profile_ids: [48],
        }
      );
    });

    it('keeps communication thread ids from native voice status updates', () => {
      const callsStore = useCallsStore();

      callsStore.addCall({
        callSid: 'sipuni:provider-call-thread-1',
        status: 'ringing',
        callDirection: 'inbound',
        provider: 'sipuni',
        conversationId: 627,
      });

      actionCable.onReceived({
        event: 'voice_call.status_changed',
        data: {
          account_id: 1,
          call_sid: 'sipuni:provider-call-thread-1',
          status: 'ringing',
          provider: 'sipuni',
          call_direction: 'inbound',
          conversation_id: 627,
          communication_thread_id: 72,
        },
      });

      expect(callsStore.incomingCalls[0]).toMatchObject({
        callSid: 'sipuni:provider-call-thread-1',
        communicationThreadId: 72,
      });
    });

    it('removes native voice calls from lightweight terminal status events', async () => {
      const callsStore = useCallsStore();

      callsStore.addCall({
        callSid: 'sipuni:provider-call-1',
        status: 'ringing',
        callDirection: 'inbound',
        provider: 'sipuni',
        conversationId: 627,
        logicalCallKey: 'sipuni:provider-call-1',
      });

      actionCable.onReceived({
        event: 'voice_call.status_changed',
        data: {
          account_id: 1,
          call_sid: 'sipuni:provider-call-1',
          status: 'completed',
          provider: 'sipuni',
          call_direction: 'inbound',
          conversation_id: 627,
          logical_call_key: 'sipuni:provider-call-1',
        },
      });

      await vi.waitFor(() => {
        expect(callsStore.calls).toEqual([]);
      });
    });

    it('dismisses native voice calls when claimed by another operator', async () => {
      const callsStore = useCallsStore();

      callsStore.addCall({
        callSid: 'sipuni-inbound-1',
        status: 'ringing',
        callDirection: 'inbound',
        provider: 'sipuni',
        conversationId: 627,
        logicalCallKey: 'sipuni-inbound:shared-key',
      });

      actionCable.onReceived({
        event: 'voice_call.claimed',
        data: {
          account_id: 1,
          call_sid: 'sipuni-inbound-2',
          provider: 'sipuni',
          call_direction: 'inbound',
          conversation_id: 627,
          logical_call_key: 'sipuni-inbound:shared-key',
          related_call_sids: ['sipuni-inbound-1', 'sipuni-inbound-2'],
          claimed_by_user_id: 9,
        },
      });

      await vi.waitFor(() => {
        expect(callsStore.calls).toEqual([]);
      });
    });

    it('should reject account-scoped events without account_id', () => {
      actionCable.onReceived({
        event: 'copilot.message.created',
        data: { id: 3, content: 'missing account' },
      });

      expect(mockDispatch).not.toHaveBeenCalledWith(
        'copilotMessages/upsert',
        expect.any(Object)
      );
    });

    it('should reconnect the active media-server call when agent peer disconnects', async () => {
      const callsStore = useWhatsappCallsStore();
      callsStore.setActiveCall({ id: 42, callId: 'provider-call-1' });

      await actionCable.onWhatsappCallAgentDisconnected({
        account_id: 1,
        id: 42,
        call_id: 'provider-call-1',
      });

      expect(reconnectMock).toHaveBeenCalledWith(42);
      expect(handleAgentOfferMock).toHaveBeenCalledWith(42, 'fresh-offer', [], {
        direction: 'unknown',
        context: 'reconnect',
      });
      expect(callsStore.activeCall.status).toBe('connected');
      expect(callsStore.isReconnecting).toBe(false);
    });

    it('clears the active media-server call when reconnect sees closed media leg', async () => {
      const callsStore = useWhatsappCallsStore();
      callsStore.setActiveCall({ id: 42, callId: 'provider-call-1' });
      const error = { response: { data: { code: 'media_leg_closed' } } };
      reconnectMock.mockRejectedValue(error);
      isMediaLegClosedErrorMock.mockReturnValue(true);

      await actionCable.onWhatsappCallAgentDisconnected({
        account_id: 1,
        id: 42,
        call_id: 'provider-call-1',
      });

      expect(isMediaLegClosedErrorMock).toHaveBeenCalledWith(error);
      expect(handleMediaLegClosedMock).toHaveBeenCalledWith(callsStore);
      expect(callsStore.isReconnecting).toBe(false);
    });

    it('stores incoming WhatsApp call communication thread id for unified routing', () => {
      const callsStore = useWhatsappCallsStore();

      actionCable.onWhatsappCallIncoming({
        id: 42,
        call_id: 'provider-call-1',
        direction: 'incoming',
        inbox_id: 7,
        conversation_id: 13743,
        conversation_display_id: 481,
        communication_thread_id: 25,
        caller: { name: 'Ahan' },
        media_server_enabled: true,
      });

      expect(callsStore.incomingCalls[0]).toMatchObject({
        conversationId: 13743,
        conversationDisplayId: 481,
        communicationThreadId: 25,
      });
    });

    it('prewarms an incoming agent offer for pre-accept negotiation without posting agent answer yet', () => {
      const callsStore = useWhatsappCallsStore();

      actionCable.onWhatsappCallIncoming({
        id: 52,
        call_id: 'provider-call-52',
        direction: 'inbound',
        inbox_id: 7,
        conversation_id: 13752,
        conversation_display_id: 492,
        caller: { name: 'Ahan' },
        media_server_enabled: true,
        media_session_id: 'media-52',
        agent_offer: { sdp_offer: 'early-agent-offer', ice_servers: [] },
      });

      expect(callsStore.incomingCalls[0]).toMatchObject({
        id: 52,
        callId: 'provider-call-52',
        mediaSessionId: 'media-52',
        agentOffer: { sdp_offer: 'early-agent-offer', ice_servers: [] },
      });
      expect(prewarmInboundAgentAnswerForCallMock).toHaveBeenCalledWith(
        expect.objectContaining({
          id: 52,
          callId: 'provider-call-52',
          agentOffer: { sdp_offer: 'early-agent-offer', ice_servers: [] },
        })
      );
      expect(handleAgentOfferMock).not.toHaveBeenCalled();
    });

    it('keeps an early inbound agent offer until the call becomes active', () => {
      const callsStore = useWhatsappCallsStore();

      actionCable.onWhatsappCallAgentOffer({
        id: 42,
        call_id: 'provider-call-1',
        sdp_offer: 'early-offer',
        ice_servers: [],
      });

      expect(handleAgentOfferMock).not.toHaveBeenCalled();
      expect(
        callsStore.consumePendingAgentOffer({
          id: 42,
          callId: 'provider-call-1',
        })
      ).toMatchObject({
        sdp_offer: 'early-offer',
        ice_servers: [],
      });
    });

    it('clears matching pending agent offers when a call ends before accept', () => {
      const callsStore = useWhatsappCallsStore();
      callsStore.storePendingAgentOffer({
        id: 42,
        call_id: 'provider-call-1',
        sdp_offer: 'stale-offer',
        ice_servers: [],
      });

      actionCable.onWhatsappCallEnded({
        id: 42,
        call_id: 'provider-call-1',
      });

      expect(
        callsStore.consumePendingAgentOffer({
          id: 42,
          callId: 'provider-call-1',
        })
      ).toBeNull();
      expect(clearPreparedInboundAgentAnswerMock).toHaveBeenCalledWith(
        {
          id: 42,
          call_id: 'provider-call-1',
        },
        { cleanupWebrtc: true }
      );
    });

    it('stores matching agent offer while provider accept is still in flight', () => {
      const callsStore = useWhatsappCallsStore();
      callsStore.setActiveCall({
        id: 42,
        callId: 'provider-call-1',
        serverRelay: true,
        providerAccepting: true,
        agentWebrtcConnected: false,
        agentWebrtcConnecting: false,
        status: 'ringing',
      });

      actionCable.onWhatsappCallAgentOffer({
        id: 42,
        call_id: 'provider-call-1',
        peer_id: 'peer-42',
        sdp_offer: 'accept-inflight-offer',
        ice_servers: [],
      });

      expect(handleAgentOfferMock).not.toHaveBeenCalled();
      expect(
        callsStore.consumePendingAgentOffer({
          id: 42,
          callId: 'provider-call-1',
        })
      ).toMatchObject({
        peer_id: 'peer-42',
        sdp_offer: 'accept-inflight-offer',
        ice_servers: [],
      });
    });

    it('ignores a late duplicate agent offer after synchronous accept response connected WebRTC', () => {
      const callsStore = useWhatsappCallsStore();
      callsStore.setActiveCall({
        id: 42,
        callId: 'provider-call-1',
        serverRelay: true,
        agentWebrtcConnected: true,
        status: 'connected',
      });

      actionCable.onWhatsappCallAgentOffer({
        id: 42,
        call_id: 'provider-call-1',
        sdp_offer: 'late-offer',
        ice_servers: [],
      });

      expect(handleAgentOfferMock).not.toHaveBeenCalled();
    });

    it('ignores a duplicate agent offer while synchronous accept response WebRTC is connecting', () => {
      const callsStore = useWhatsappCallsStore();
      callsStore.setActiveCall({
        id: 42,
        callId: 'provider-call-1',
        serverRelay: true,
        agentWebrtcConnected: false,
        agentWebrtcConnecting: true,
        status: 'in_progress',
      });

      actionCable.onWhatsappCallAgentOffer({
        id: 42,
        call_id: 'provider-call-1',
        sdp_offer: 'duplicate-offer',
        ice_servers: [],
      });

      expect(handleAgentOfferMock).not.toHaveBeenCalled();
    });

    it('waits for outbound accepted before marking a server-relay outbound call connected after agent offer', async () => {
      const callsStore = useWhatsappCallsStore();
      callsStore.setActiveCall({
        id: 42,
        callId: 'provider-call-1',
        direction: 'outbound',
        status: 'ringing',
        serverRelay: true,
      });

      await actionCable.onWhatsappCallOutboundConnected({
        id: 42,
        call_id: 'provider-call-1',
        sdp_offer: 'agent-offer',
        ice_servers: [],
      });

      expect(handleAgentOfferMock).toHaveBeenCalledWith(42, 'agent-offer', [], {
        direction: 'outbound',
        context: 'outbound-connected',
      });
      expect(callsStore.activeCall.agentWebrtcConnected).toBe(true);
      expect(callsStore.activeCall.agentWebrtcConnecting).toBe(false);
      expect(callsStore.activeCall.status).toBe('ringing');
      expect(emitter.emit).not.toHaveBeenCalledWith(
        'whatsapp_call:agent_webrtc_connected'
      );

      actionCable.onWhatsappCallOutboundAccepted({
        id: 42,
        call_id: 'provider-call-1',
      });

      expect(callsStore.activeCall.status).toBe('connected');
      expect(emitter.emit).toHaveBeenCalledWith(
        'whatsapp_call:agent_webrtc_connected'
      );
    });

    it('does not start a server-relay outbound timer until agent WebRTC is connected', async () => {
      const callsStore = useWhatsappCallsStore();
      callsStore.setActiveCall({
        id: 42,
        callId: 'provider-call-1',
        direction: 'outbound',
        status: 'ringing',
        serverRelay: true,
      });

      actionCable.onWhatsappCallOutboundAccepted({
        id: 42,
        call_id: 'provider-call-1',
      });

      expect(callsStore.activeCall.metaAccepted).toBe(true);
      expect(callsStore.activeCall.status).toBe('ringing');
      expect(emitter.emit).not.toHaveBeenCalledWith(
        'whatsapp_call:agent_webrtc_connected'
      );

      await actionCable.onWhatsappCallOutboundConnected({
        id: 42,
        call_id: 'provider-call-1',
        sdp_offer: 'agent-offer',
        ice_servers: [],
      });

      expect(callsStore.activeCall.status).toBe('connected');
      expect(emitter.emit).toHaveBeenCalledWith(
        'whatsapp_call:agent_webrtc_connected'
      );
    });

    it('starts legacy outbound recording and timer only on outbound accepted', () => {
      const callsStore = useWhatsappCallsStore();
      const pc = { setRemoteDescription: vi.fn().mockResolvedValue() };
      const stream = {};
      callsStore.setActiveCall({
        id: 42,
        callId: 'provider-call-legacy',
        direction: 'outbound',
        status: 'ringing',
        serverRelay: false,
      });
      const outboundState = getOutboundCallState();
      outboundState.pc = pc;
      outboundState.stream = stream;
      outboundState.callId = 'provider-call-legacy';

      actionCable.onWhatsappCallOutboundConnected({
        call_id: 'provider-call-legacy',
        sdp_answer: 'answer',
      });

      expect(startCallRecordingMock).not.toHaveBeenCalled();

      actionCable.onWhatsappCallOutboundAccepted({
        call_id: 'provider-call-legacy',
      });

      expect(startCallRecordingMock).toHaveBeenCalledWith(pc, stream, 42);
      expect(callsStore.activeCall.status).toBe('connected');
    });
    it('should emit dashboard bus events for CRM deal ActionCable events', () => {
      const dealPayload = {
        account_id: 1,
        deal: { id: 42, title: 'Realtime Deal' },
        meta: { event_type: 'deal_created' },
      };

      actionCable.onReceived({
        event: 'crm.deal.created',
        data: dealPayload,
      });

      expect(emitter.emit).toHaveBeenCalledWith(
        BUS_EVENTS.CRM_DEAL_REALTIME_EVENT,
        {
          event: 'crm.deal.created',
          ...dealPayload,
        }
      );
    });

    it('should refresh dialog CRM counters after CRM deal ActionCable events', async () => {
      vi.useFakeTimers();
      const crmReferencesStore = useCrmReferencesStore();
      const loadPipelinesSpy = vi
        .spyOn(crmReferencesStore, 'loadPipelines')
        .mockResolvedValue([]);
      const dealPayload = {
        account_id: 1,
        deal: { id: 42, title: 'Realtime Deal' },
        meta: { event_type: 'deal_created' },
      };

      try {
        actionCable.onReceived({
          event: 'crm.deal.created',
          data: dealPayload,
        });

        expect(sidebarUnreadRefreshCalls()).toHaveLength(0);
        expect(loadPipelinesSpy).not.toHaveBeenCalled();

        await vi.advanceTimersByTimeAsync(500);

        expect(sidebarUnreadRefreshCalls()).toHaveLength(0);
        expect(loadPipelinesSpy).toHaveBeenCalledTimes(1);

        await vi.advanceTimersByTimeAsync(500);

        expect(sidebarUnreadRefreshCalls()).toHaveLength(1);
      } finally {
        vi.useRealTimers();
      }
    });

    it('should reject CRM deal events without account_id', () => {
      actionCable.onReceived({
        event: 'crm.deal.created',
        data: { deal: { id: 42, title: 'Missing account' } },
      });

      expect(emitter.emit).not.toHaveBeenCalledWith(
        BUS_EVENTS.CRM_DEAL_REALTIME_EVENT,
        expect.any(Object)
      );
    });
  });
});
