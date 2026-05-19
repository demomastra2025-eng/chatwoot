import { describe, it, beforeEach, expect, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import ActionCableConnector from '../actionCable';
import {
  getOutboundCallState,
  useWhatsappCallsStore,
} from 'dashboard/stores/whatsappCalls';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';

const {
  reconnectMock,
  handleAgentOfferMock,
  handleMediaLegClosedMock,
  isMediaLegClosedErrorMock,
  startCallRecordingMock,
} = vi.hoisted(() => ({
  reconnectMock: vi.fn(),
  handleAgentOfferMock: vi.fn(),
  handleMediaLegClosedMock: vi.fn(),
  isMediaLegClosedErrorMock: vi.fn(() => false),
  startCallRecordingMock: vi.fn(),
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
  handleAgentOffer: handleAgentOfferMock,
  handleMediaLegClosed: handleMediaLegClosedMock,
  isMediaLegClosedError: isMediaLegClosedErrorMock,
  startCallRecording: startCallRecordingMock,
}));

vi.mock('dashboard/api/whatsappCalls', () => ({
  default: {
    reconnect: reconnectMock,
  },
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
    reconnectMock.mockResolvedValue({
      data: { sdp_offer: 'fresh-offer', ice_servers: [] },
    });
    handleAgentOfferMock.mockResolvedValue();
    isMediaLegClosedErrorMock.mockReturnValue(false);
    mockDispatch = vi.fn();
    store = {
      $store: {
        dispatch: mockDispatch,
        getters: {
          getCurrentAccountId: 1,
        },
      },
    };

    actionCable = ActionCableConnector.init(store.$store, 'test-token');
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
      expect(handleAgentOfferMock).toHaveBeenCalledWith(42, 'fresh-offer', []);
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

    it('stores incoming WhatsApp call conversation display id for native conversation routing', () => {
      const callsStore = useWhatsappCallsStore();

      actionCable.onWhatsappCallIncoming({
        id: 42,
        call_id: 'provider-call-1',
        direction: 'incoming',
        inbox_id: 7,
        conversation_id: 13743,
        conversation_display_id: 481,
        caller: { name: 'Ahan' },
        media_server_enabled: true,
      });

      expect(callsStore.incomingCalls[0]).toMatchObject({
        conversationId: 13743,
        conversationDisplayId: 481,
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

      expect(handleAgentOfferMock).toHaveBeenCalledWith(42, 'agent-offer', []);
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
