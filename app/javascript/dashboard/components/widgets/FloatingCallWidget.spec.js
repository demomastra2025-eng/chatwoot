import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mockSession = vi.hoisted(() => ({
  activeCall: null,
  incomingCalls: [],
  hasActiveCall: false,
  isJoining: false,
  canHandleCallInBrowser: vi.fn(call => call?.browserJoinSupported !== false),
  joinCall: vi.fn(),
  endCall: vi.fn(),
  rejectIncomingCall: vi.fn(),
  dismissCall: vi.fn(),
  formattedCallDuration: '00:00',
}));

const storeGetters = vi.hoisted(() => ({
  getConversationById: vi.fn(),
  getInbox: vi.fn(),
  getAgentById: vi.fn(),
}));

const t = (key, params = {}) => {
  const translations = {
    'CONVERSATION.VOICE_WIDGET.INCOMING_CALL': 'Incoming call',
    'CONVERSATION.VOICE_WIDGET.OUTGOING_CONNECTING_OPERATOR':
      'Connecting the operator',
    'CONVERSATION.VOICE_WIDGET.OUTGOING_CALLING_CUSTOMER':
      'Calling the customer',
    'CONVERSATION.VOICE_WIDGET.OUTGOING_CLIENT_RINGING': 'Customer is ringing',
    'CONVERSATION.VOICE_WIDGET.INBOUND_DIRECTION': 'Inbound',
    'CONVERSATION.VOICE_WIDGET.OUTBOUND_DIRECTION': 'Outbound',
    'CONVERSATION.VOICE_WIDGET.ROUTE_SEPARATOR': '→',
    'CONVERSATION.VOICE_WIDGET.CALL_ROUTE': `${params.from} → ${params.to}`,
    'CONVERSATION.VOICE_WIDGET.CALL_DIRECTION_ROUTE': `${params.direction} · ${params.route}`,
    'CONVERSATION.VOICE_WIDGET.HANDLED_OUTSIDE_BROWSER':
      'Handled outside the browser',
    'CONVERSATION.VOICE_WIDGET.HANDLED_BY': `Handled by: ${params.name}`,
    'CONVERSATION.VOICE_WIDGET.HANDLED_BY_UNKNOWN':
      'Handled by another operator',
    'CONVERSATION.VOICE_WIDGET.CALL_IN_PROGRESS': 'Call in progress',
    'CONVERSATION.VOICE_WIDGET.BROWSER_CALLING_UNAVAILABLE':
      'Browser calling unavailable',
    'CONVERSATION.VOICE_WIDGET.UNKNOWN_CALLER': 'Unknown caller',
    'CONVERSATION.VOICE_WIDGET.DEFAULT_INBOX_NAME': 'Customer support',
    'CONVERSATION.VOICE_WIDGET.REJECT_CALL': 'Reject',
    'CONVERSATION.VOICE_WIDGET.CALL': 'Call',
    'CONVERSATION.VOICE_WIDGET.OPEN_CHAT': 'Chat',
    'CONVERSATION.VOICE_WIDGET.CLOSE': 'Close',
  };

  return translations[key] || key;
};

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t }),
}));

vi.mock('vue-router', async () => {
  const { ref } = await vi.importActual('vue');
  return {
    useRouter: () => ({
      currentRoute: ref({ params: { accountId: 1 }, name: 'conversation' }),
      push: vi.fn(),
    }),
  };
});

vi.mock('vuex', () => ({
  useStore: () => ({
    getters: {
      getConversationById: storeGetters.getConversationById,
      'inboxes/getInbox': storeGetters.getInbox,
      'agents/getAgentById': storeGetters.getAgentById,
    },
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/helper/AudioAlerts/WindowVisibilityHelper', () => ({
  default: { isWindowVisible: () => false },
}));

vi.mock('dashboard/helper/voiceCallStage', () => ({
  OUTBOUND_CALL_STAGE_LABEL_KEYS: {
    CONNECTING_OPERATOR: 'connecting_operator',
    CALLING_CUSTOMER: 'calling_customer',
    CUSTOMER_RINGING: 'customer_ringing',
    IN_PROGRESS: 'in_progress',
  },
  getOutboundCallStageLabelKey: () => 'in_progress',
  outboundCallStageShowsDuration: () => true,
}));

vi.mock('dashboard/composables/useCallSession', async () => {
  const { computed } = await vi.importActual('vue');
  return {
    useCallSession: () => ({
      activeCall: computed(() => mockSession.activeCall),
      incomingCalls: computed(() => mockSession.incomingCalls),
      hasActiveCall: computed(() => mockSession.hasActiveCall),
      isJoining: computed(() => mockSession.isJoining),
      canHandleCallInBrowser: mockSession.canHandleCallInBrowser,
      joinCall: mockSession.joinCall,
      endCall: mockSession.endCall,
      rejectIncomingCall: mockSession.rejectIncomingCall,
      dismissCall: mockSession.dismissCall,
      formattedCallDuration: computed(() => mockSession.formattedCallDuration),
    }),
  };
});

import FloatingCallWidget from './FloatingCallWidget.vue';

const mountComponent = () =>
  mount(FloatingCallWidget, {
    global: {
      mocks: { $t: t },
      stubs: {
        Avatar: { template: '<div class="avatar" />' },
      },
    },
  });

describe('FloatingCallWidget', () => {
  beforeEach(() => {
    mockSession.activeCall = null;
    mockSession.incomingCalls = [];
    mockSession.hasActiveCall = false;
    mockSession.isJoining = false;
    mockSession.canHandleCallInBrowser.mockImplementation(
      call => call?.browserJoinSupported !== false
    );
    mockSession.joinCall.mockReset();
    mockSession.endCall.mockReset();
    mockSession.rejectIncomingCall.mockReset();
    mockSession.dismissCall.mockReset();
    storeGetters.getConversationById.mockReset();
    storeGetters.getInbox.mockReset();
    storeGetters.getAgentById.mockReset();
  });

  it('shows outside-browser operator, direction, route, and close action', async () => {
    mockSession.incomingCalls = [
      {
        callSid: 'call-claimed-1',
        conversationId: 42,
        inboxId: 7,
        provider: 'fonoster',
        callDirection: 'inbound',
        browserJoinSupported: false,
        fromNumber: 'client-party',
        toNumber: 'support-line',
        operatorClaim: { user_id: 9, user_name: 'Ayan' },
      },
    ];
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 7,
      meta: { sender: { name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({
      id: 7,
      name: 'Sales',
      provider: 'fonoster',
    });

    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('Handled outside the browser');
    expect(wrapper.text()).toContain('client-party→support-line');
    expect(wrapper.find('[aria-label="Reject"]').exists()).toBe(true);
    expect(wrapper.find('[aria-label="Chat"]').exists()).toBe(true);

    await wrapper.get('[aria-label="Close"]').trigger('click');

    expect(mockSession.dismissCall).toHaveBeenCalledWith('call-claimed-1');
  });
});
