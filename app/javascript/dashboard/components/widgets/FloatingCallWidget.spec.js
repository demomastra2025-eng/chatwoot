import { flushPromises, mount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

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
  getSelectedChat: null,
}));

const routerMock = vi.hoisted(() => ({
  currentRoute: null,
  push: vi.fn(),
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
    'CONVERSATION.VOICE_WIDGET.OPERATOR_EXTENSION': `ext. ${params.extension}`,
    'CONVERSATION.VOICE_WIDGET.OPERATOR_LABEL': `Manager: ${params.name}`,
    'CONVERSATION.VOICE_WIDGET.OPERATOR_WITH_EXTENSION': `${params.name} (${params.extension})`,
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
    'CONVERSATION.VOICE_WIDGET.END_CALL': 'End call',
  };

  return translations[key] || key;
};

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t }),
}));

vi.mock('vue-router', async () => {
  const { ref } = await vi.importActual('vue');
  routerMock.currentRoute = ref({
    params: { accountId: 1 },
    query: {},
    name: 'conversation',
  });
  return {
    useRouter: () => routerMock,
  };
});

vi.mock('vuex', () => ({
  useStore: () => ({
    getters: {
      getConversationById: storeGetters.getConversationById,
      'inboxes/getInbox': storeGetters.getInbox,
      'agents/getAgentById': storeGetters.getAgentById,
      getSelectedChat: storeGetters.getSelectedChat,
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
    routerMock.currentRoute.value = {
      params: { accountId: 1 },
      query: {},
      name: 'conversation',
    };
    routerMock.push.mockReset();
    storeGetters.getConversationById.mockReset();
    storeGetters.getInbox.mockReset();
    storeGetters.getAgentById.mockReset();
    storeGetters.getSelectedChat = null;
  });

  afterEach(() => {
    vi.useRealTimers();
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
    expect(wrapper.text()).toContain('Ayan');
    expect(wrapper.text()).not.toContain('Manager: Ayan');
    expect(wrapper.find('[aria-label="Reject"]').exists()).toBe(true);
    expect(wrapper.find('[aria-label="Chat"]').exists()).toBe(true);

    await wrapper.get('[aria-label="Close"]').trigger('click');

    expect(mockSession.dismissCall).not.toHaveBeenCalled();
    expect(wrapper.text()).not.toContain('Handled outside the browser');
  });

  it('shows elapsed ringing time for a pending outbound call', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-07-03T06:00:00Z'));
    mockSession.incomingCalls = [
      {
        callSid: 'asterisk_analog:local:ringing-outbound',
        conversationId: 724,
        inboxId: 4771,
        provider: 'asterisk_analog',
        callDirection: 'outbound',
        browserJoined: true,
        fromNumber: '+77172705175',
        toNumber: '+77066318623',
      },
    ];
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 4771,
      meta: { sender: { name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({
      id: 4771,
      name: 'Asterisk',
      provider: 'asterisk_analog',
    });

    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('00:00');

    await vi.advanceTimersByTimeAsync(3000);

    expect(wrapper.text()).toContain('00:03');
    wrapper.unmount();
  });

  it('opens a communication thread instead of the underlying voice inbox conversation', async () => {
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:1782820473.488058',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        fromNumber: '+77070001002',
        toNumber: '+77070001001',
      },
    ];
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 4769,
      communication_thread_id: 72,
      meta: { sender: { name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({
      id: 4769,
      name: 'Sipuni',
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    await wrapper.get('[aria-label="Chat"]').trigger('click');

    expect(routerMock.push).toHaveBeenCalledWith({
      name: 'communication_thread_conversation',
      params: {
        accountId: 1,
        communication_thread_id: 72,
      },
      query: {
        assignee_type: 'all',
        status: 'open',
      },
    });
  });

  it('shows all simultaneous incoming calls when there is no active call', () => {
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:incoming-1',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        fromNumber: '+77070001002',
        toNumber: '+77070001001',
      },
      {
        callSid: 'sipuni:incoming-2',
        conversationId: 725,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        fromNumber: '+77070001003',
        toNumber: '+77070001001',
      },
    ];
    storeGetters.getConversationById.mockImplementation(id => ({
      inbox_id: 4769,
      meta: { sender: { name: `Client ${id}` } },
    }));
    storeGetters.getInbox.mockReturnValue({
      id: 4769,
      name: 'Sipuni',
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('+77070001002→+77070001001');
    expect(wrapper.text()).toContain('+77070001003→+77070001001');
  });

  it('hides the active call card without ending the call', async () => {
    mockSession.hasActiveCall = true;
    mockSession.activeCall = {
      callSid: 'active-call-1',
      conversationId: 724,
      inboxId: 4769,
      provider: 'sipuni',
      callDirection: 'inbound',
      fromNumber: '+77070001002',
      toNumber: '+77070001001',
    };
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 4769,
      meta: { sender: { name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({
      id: 4769,
      name: 'Sipuni',
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    await wrapper.get('[aria-label="Close"]').trigger('click');

    expect(mockSession.endCall).not.toHaveBeenCalled();
    expect(wrapper.text()).not.toContain('+77070001002→+77070001001');
  });

  it('ends the active call from the hang up control', async () => {
    mockSession.hasActiveCall = true;
    mockSession.activeCall = {
      callSid: 'active-call-1',
      conversationId: 724,
      inboxId: 4769,
      provider: 'sipuni',
      callDirection: 'inbound',
      fromNumber: '+77070001002',
      toNumber: '+77070001001',
    };
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 4769,
      meta: { sender: { name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({
      id: 4769,
      name: 'Sipuni',
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    await wrapper.get('[aria-label="End call"]').trigger('click');

    expect(mockSession.endCall).toHaveBeenCalledWith({
      conversationId: 724,
      inboxId: 4769,
      provider: 'sipuni',
      callSid: 'active-call-1',
    });
  });

  it('opens the communication thread returned by claim after answering a call', async () => {
    mockSession.joinCall.mockResolvedValue({
      joinSupported: true,
      communicationThreadId: 72,
    });
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:1782820473.488058',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        fromNumber: '+77070001002',
        toNumber: '+77070001001',
      },
    ];
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 4769,
      meta: { sender: { name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({
      id: 4769,
      name: 'Sipuni',
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    await wrapper.get('[aria-label="Call"]').trigger('click');
    await flushPromises();

    expect(routerMock.push).toHaveBeenCalledWith({
      name: 'communication_thread_conversation',
      params: {
        accountId: 1,
        communication_thread_id: 72,
      },
      query: {
        assignee_type: 'all',
        status: 'open',
      },
    });
  });

  it('opens the communication thread returned by claim when browser join falls back', async () => {
    mockSession.joinCall.mockResolvedValue({
      joinSupported: false,
      communicationThreadId: 72,
      reason: 'sip_invite_not_received',
    });
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:1782820473.488058',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        fromNumber: '+77070001002',
        toNumber: '+77070001001',
      },
    ];
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 4769,
      meta: { sender: { name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({
      id: 4769,
      name: 'Sipuni',
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    await wrapper.get('[aria-label="Call"]').trigger('click');
    await flushPromises();

    expect(routerMock.push).toHaveBeenCalledWith({
      name: 'communication_thread_conversation',
      params: {
        accountId: 1,
        communication_thread_id: 72,
      },
      query: {
        assignee_type: 'all',
        status: 'open',
      },
    });
    expect(routerMock.push).not.toHaveBeenCalledWith(
      expect.objectContaining({
        name: 'conversation_through_inbox',
      })
    );
  });

  it('keeps a retryable incoming claim on the current page', async () => {
    mockSession.joinCall.mockResolvedValue({
      joinSupported: false,
      retryable: true,
      reason: 'sipuni_operator_leg_not_ready',
    });
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:1782820473.488058',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        fromNumber: '+77070001002',
        toNumber: '+77070001001',
      },
    ];
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 4769,
      meta: { sender: { name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({
      id: 4769,
      name: 'Sipuni',
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    await wrapper.get('[aria-label="Call"]').trigger('click');
    await flushPromises();

    expect(routerMock.push).not.toHaveBeenCalled();
  });

  it('keeps numbers in the route and shows the Sipuni manager on the second line', () => {
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:1782820473.488058',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        fromNumber: '+77070001002',
        toNumber: '+77070001001',
        operatorCandidates: [
          { user_id: 179, name: 'John', internal_extension: '502' },
        ],
        operatorInternalExtension: '502',
      },
    ];
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 4769,
      meta: { sender: { name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({
      id: 4769,
      name: 'Sipuni',
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('+77070001002→+77070001001');
    expect(wrapper.text()).toContain('John (502)');
    expect(wrapper.text()).not.toContain('Manager: John (502)');
  });

  it('does not leave the current concrete conversation for the same contact', async () => {
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:1782820473.488058',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        contactId: 2179,
      },
    ];
    storeGetters.getSelectedChat = {
      id: 724,
      contact_id: 2179,
    };
    routerMock.currentRoute.value = {
      params: { accountId: 1, inbox_id: 4769, conversation_id: 724 },
      query: { status: 'open', assignee_type: 'all' },
      name: 'conversation_through_inbox',
    };
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 4769,
      contact_id: 2179,
      meta: { sender: { id: 2179, name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({
      id: 4769,
      name: 'Sipuni',
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    await wrapper.get('[aria-label="Chat"]').trigger('click');

    expect(routerMock.push).not.toHaveBeenCalled();
  });
});
