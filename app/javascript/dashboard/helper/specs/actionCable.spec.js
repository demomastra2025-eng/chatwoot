import { describe, it, beforeEach, expect, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import ActionCableConnector from '../actionCable';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';

const { reconnectMock, handleAgentOfferMock } = vi.hoisted(() => ({
  reconnectMock: vi.fn(),
  handleAgentOfferMock: vi.fn(),
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
  });
});
