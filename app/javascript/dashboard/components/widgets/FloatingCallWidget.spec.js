import { flushPromises, mount } from '@vue/test-utils';
import { ref as makeRef } from 'vue';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const microphoneState = vi.hoisted(() => ({
  available: null,
  muted: null,
  toggle: vi.fn(),
}));

const mockSession = vi.hoisted(() => ({
  activeCall: null,
  incomingCalls: [],
  hasActiveCall: false,
  isJoining: false,
  canHandleCallInBrowser: vi.fn(call => call?.browserJoinSupported !== false),
  isIncomingCallActionableInBrowser: vi.fn(
    call => call?.callDirection === 'inbound'
  ),
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
  getCurrentUser: null,
}));

const routerMock = vi.hoisted(() => ({
  currentRoute: null,
  push: vi.fn(),
}));

const ringtoneState = vi.hoisted(() => ({
  sourceId: null,
  isActive: null,
}));

const whatsappCallsState = vi.hoisted(() => ({
  hasActiveCall: false,
  isAccepting: false,
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
    'CONVERSATION.VOICE_WIDGET.HANDLED_BY_AI_AGENT': 'Handled by AI agent',
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
      getCurrentUser: storeGetters.getCurrentUser,
    },
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/stores/whatsappCalls', () => ({
  useWhatsappCallsStore: () => whatsappCallsState,
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
      isIncomingCallActionableInBrowser:
        mockSession.isIncomingCallActionableInBrowser,
      joinCall: mockSession.joinCall,
      endCall: mockSession.endCall,
      rejectIncomingCall: mockSession.rejectIncomingCall,
      dismissCall: mockSession.dismissCall,
      formattedCallDuration: computed(() => mockSession.formattedCallDuration),
    }),
  };
});

vi.mock('dashboard/composables/useIncomingCallRingtone', () => ({
  useIncomingCallRingtone: (sourceId, isActive) => {
    ringtoneState.sourceId = sourceId;
    ringtoneState.isActive = isActive;
  },
}));
vi.mock('dashboard/composables/useSipMicrophone', () => ({
  useSipMicrophone: () => ({
    microphoneAvailable: microphoneState.available,
    microphoneMuted: microphoneState.muted,
    toggleMicrophone: microphoneState.toggle,
  }),
}));

import FloatingCallWidget from './FloatingCallWidget.vue';

const mountComponent = (props = {}) =>
  mount(FloatingCallWidget, {
    props,
    global: {
      mocks: { $t: t },
      stubs: {
        Avatar: { template: '<div class="avatar" />' },
      },
    },
  });

describe('FloatingCallWidget', () => {
  beforeEach(() => {
    microphoneState.available = makeRef(false);
    microphoneState.muted = makeRef(false);
    microphoneState.toggle.mockReset();
    mockSession.activeCall = null;
    mockSession.incomingCalls = [];
    mockSession.hasActiveCall = false;
    mockSession.isJoining = false;
    whatsappCallsState.hasActiveCall = false;
    whatsappCallsState.isAccepting = false;
    mockSession.canHandleCallInBrowser.mockImplementation(
      call => call?.browserJoinSupported !== false
    );
    mockSession.isIncomingCallActionableInBrowser.mockImplementation(
      call => call?.callDirection === 'inbound'
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
    storeGetters.getCurrentUser = null;
    ringtoneState.sourceId = null;
    ringtoneState.isActive = null;
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('rings for a visible pending inbound voice call', () => {
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:incoming-ringtone',
        callDirection: 'inbound',
        status: 'ringing',
      },
    ];

    const wrapper = mountComponent();

    expect(ringtoneState.sourceId).toBe('voice');
    expect(ringtoneState.isActive.value).toBe(true);
    wrapper.unmount();
  });

  it('shows one logical inbound call and selects the local Janus branch', async () => {
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:branch-202',
        provider: 'sipuni',
        inboxId: 194,
        sipProfileId: 72,
        janusSessionKey: 'sip_profile:72',
        janusCallRef: 'branch-202',
        logicalCallKey: 'janus-inbound:shared',
        callDirection: 'inbound',
        status: 'ringing',
      },
      {
        callSid: 'sipuni:branch-207',
        provider: 'sipuni',
        inboxId: 194,
        sipProfileId: 78,
        janusSessionKey: 'sip_profile:78',
        janusCallRef: 'branch-207',
        logicalCallKey: 'janus-inbound:shared',
        callDirection: 'inbound',
        status: 'ringing',
      },
    ];
    mockSession.isIncomingCallActionableInBrowser.mockImplementation(
      call => call?.sipProfileId === 78
    );
    storeGetters.getConversationById.mockReturnValue({ inbox_id: 194 });
    storeGetters.getInbox.mockReturnValue({
      id: 194,
      name: 'Sipuni',
      provider: 'sipuni',
    });
    mockSession.joinCall.mockResolvedValue({ joined: true });

    const wrapper = mountComponent();

    expect(wrapper.findAll('[aria-label="Call"]')).toHaveLength(1);
    expect(ringtoneState.isActive.value).toBe(true);
    await wrapper.get('[aria-label="Call"]').trigger('click');

    expect(mockSession.joinCall).toHaveBeenCalledWith(
      expect.objectContaining({
        callSid: 'sipuni:branch-207',
        sipProfileId: 78,
        janusCallRef: 'branch-207',
        janusSessionKey: 'sip_profile:78',
      })
    );
    wrapper.unmount();
  });

  it('exposes the active-call microphone even when the phone panel is hidden', async () => {
    mockSession.activeCall = {
      callSid: 'sipuni:connected-1',
      provider: 'sipuni',
      inboxId: 194,
      sipProfileId: 72,
      janusSessionKey: 'sip_profile:72',
      isActive: true,
      status: 'in_progress',
    };
    mockSession.hasActiveCall = true;
    storeGetters.getInbox.mockReturnValue({
      id: 194,
      name: 'Sipuni',
      provider: 'sipuni',
    });
    const wrapper = mountComponent();

    const microphone = wrapper.get('[data-testid="floating-call-microphone"]');
    expect(microphone.attributes('disabled')).toBeDefined();
    microphone.element.click();
    expect(microphoneState.toggle).not.toHaveBeenCalled();

    microphoneState.available.value = true;
    await wrapper.vm.$nextTick();
    expect(microphone.attributes('disabled')).toBeUndefined();
    expect(microphone.attributes('aria-pressed')).toBe('false');
    expect(microphone.classes()).toContain('bg-n-alpha-2');
    expect(microphone.classes()).not.toContain('bg-n-ruby-9');
    expect(microphone.attributes('aria-label')).toBe(
      'PHONE_WIDGET.MUTE_MICROPHONE'
    );
    expect(wrapper.find('[data-testid="call-microphone-off"]').exists()).toBe(
      false
    );
    await microphone.trigger('click');
    expect(microphoneState.toggle).toHaveBeenCalledOnce();
    microphoneState.muted.value = true;
    await wrapper.vm.$nextTick();
    expect(microphone.find('.i-lucide-mic-off').exists()).toBe(true);
    expect(microphone.attributes('aria-pressed')).toBe('true');
    // Muted is a filled red button with its own label, not just another icon,
    // and the card says so in words.
    expect(microphone.classes()).toEqual(
      expect.arrayContaining(['bg-n-ruby-9', 'text-white'])
    );
    expect(microphone.classes()).not.toContain('bg-n-alpha-2');
    expect(microphone.attributes('aria-label')).toBe(
      'PHONE_WIDGET.MICROPHONE_MUTED'
    );
    expect(microphone.attributes('title')).toBe(
      'PHONE_WIDGET.MICROPHONE_MUTED'
    );
    expect(wrapper.get('[data-testid="call-microphone-off"]').text()).toBe(
      'PHONE_WIDGET.MICROPHONE_OFF'
    );

    microphoneState.muted.value = false;
    await wrapper.vm.$nextTick();
    expect(microphone.attributes('aria-pressed')).toBe('false');
    expect(microphone.classes()).not.toContain('bg-n-ruby-9');
    expect(wrapper.find('[data-testid="call-microphone-off"]').exists()).toBe(
      false
    );
    wrapper.unmount();
  });

  it('keeps one active card when a sibling ringing branch is still present', () => {
    mockSession.activeCall = {
      callSid: 'sipuni:branch-202',
      provider: 'sipuni',
      inboxId: 194,
      logicalCallKey: 'janus-inbound:active-shared',
      callDirection: 'inbound',
      status: 'in_progress',
      isActive: true,
      browserJoinSupported: true,
    };
    mockSession.hasActiveCall = true;
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:branch-207',
        provider: 'sipuni',
        inboxId: 194,
        logicalCallKey: 'janus-inbound:active-shared',
        callDirection: 'inbound',
        status: 'ringing',
      },
    ];
    storeGetters.getConversationById.mockReturnValue({ inbox_id: 194 });
    storeGetters.getInbox.mockReturnValue({
      id: 194,
      name: 'Sipuni',
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    expect(wrapper.findAll('[aria-label="End call"]')).toHaveLength(1);
    expect(wrapper.find('[aria-label="Call"]').exists()).toBe(false);
    expect(wrapper.text()).toContain('Call in progress');
    wrapper.unmount();
  });

  it('keeps an informational inbound card silent and without call controls', () => {
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:remote-branch',
        provider: 'sipuni',
        inboxId: 194,
        logicalCallKey: 'janus-inbound:remote',
        callDirection: 'inbound',
        status: 'ringing',
      },
    ];
    mockSession.isIncomingCallActionableInBrowser.mockReturnValue(false);

    const wrapper = mountComponent();

    expect(ringtoneState.isActive.value).toBe(false);
    expect(wrapper.find('[aria-label="Call"]').exists()).toBe(false);
    expect(wrapper.find('[aria-label="Reject"]').exists()).toBe(false);
    expect(wrapper.find('[aria-label="Chat"]').exists()).toBe(true);
    wrapper.unmount();
  });

  it('does not ring for outbound or remotely handled voice calls', () => {
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:outbound-ringtone',
        callDirection: 'outbound',
        status: 'ringing',
      },
      {
        callSid: 'sipuni:handled-ringtone',
        callDirection: 'inbound',
        status: 'in_progress',
      },
    ];

    const wrapper = mountComponent();

    expect(ringtoneState.isActive.value).toBe(false);
    wrapper.unmount();
  });

  it('does not auto-join an outbound call card', async () => {
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:outbound-direct-start',
        callDirection: 'outbound',
        status: 'created',
        browserJoined: false,
      },
    ];

    const wrapper = mountComponent();
    await flushPromises();

    expect(mockSession.joinCall).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it('shows outside-browser operator, direction, route, and close action', async () => {
    mockSession.incomingCalls = [
      {
        callSid: 'call-claimed-1',
        conversationId: 42,
        inboxId: 7,
        provider: 'sipuni',
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
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    expect(ringtoneState.isActive.value).toBe(false);
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

  it('shows elapsed ringing time for a pending inbound call', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-07-03T06:00:00Z'));
    mockSession.incomingCalls = [
      {
        callSid: 'asterisk_analog:janus:incoming-ringing',
        conversationId: 724,
        inboxId: 4771,
        provider: 'asterisk_analog',
        callDirection: 'inbound',
        fromNumber: '+77066318623',
        toNumber: '+77172705175',
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

    await vi.advanceTimersByTimeAsync(5000);

    expect(wrapper.text()).toContain('00:05');
    wrapper.unmount();
  });

  it('shows active duration for calls handled by another operator', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-07-03T06:00:00Z'));
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:handled-by-other',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        status: 'in_progress',
        browserJoinSupported: false,
        operatorClaim: {
          user_name: 'Ayan',
          internal_extension: '202',
        },
        operatorInternalExtension: '207',
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

    await vi.advanceTimersByTimeAsync(7000);

    expect(wrapper.text()).toContain('Handled by: Ayan (202)');
    expect(wrapper.text().match(/Ayan/g)).toHaveLength(1);
    expect(wrapper.text()).toContain('00:07');
    expect(wrapper.find('[aria-label="Reject"]').exists()).toBe(false);
    expect(wrapper.find('[aria-label="Call"]').exists()).toBe(false);
    wrapper.unmount();
  });

  it('does not identify the handling operator from routing candidates', () => {
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:handled-without-claim',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        status: 'in_progress',
        browserJoinSupported: false,
        operatorCandidates: [
          { user_id: 179, name: 'Candidate', internal_extension: '502' },
        ],
        operatorInternalExtension: '502',
      },
    ];
    storeGetters.getConversationById.mockReturnValue({ inbox_id: 4769 });
    storeGetters.getInbox.mockReturnValue({
      id: 4769,
      name: 'Sipuni',
      provider: 'sipuni',
    });

    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('Handled by another operator');
    expect(wrapper.text()).not.toContain('Handled by: Candidate');
    wrapper.unmount();
  });

  it('shows active duration for calls handled by the AI agent', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-07-03T06:00:00Z'));
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:janus-server:49:ai-call',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        status: 'in_progress',
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'AI_AGENT_HANDLING',
        serverManagedVoiceCall: true,
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

    await vi.advanceTimersByTimeAsync(7000);

    expect(wrapper.text()).toContain('Handled by AI agent');
    expect(wrapper.text()).toContain('00:07');
    expect(wrapper.find('[aria-label="Reject"]').exists()).toBe(false);
    expect(wrapper.find('[aria-label="Call"]').exists()).toBe(false);
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

  it('keeps an incoming call visible but blocks answer while WhatsApp is active', async () => {
    whatsappCallsState.hasActiveCall = true;
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:incoming-busy',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
      },
    ];
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 4769,
      meta: { sender: { name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({ id: 4769, provider: 'sipuni' });

    const wrapper = mountComponent();
    const answerButton = wrapper.get('[aria-label="Call"]');

    expect(answerButton.attributes('disabled')).toBeDefined();
    await answerButton.trigger('click');
    expect(mockSession.endCall).not.toHaveBeenCalled();
    expect(mockSession.joinCall).not.toHaveBeenCalled();
  });

  it('blocks answering a SIP call while WhatsApp acceptance is in flight', async () => {
    whatsappCallsState.isAccepting = true;
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:incoming-whatsapp-accepting',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
      },
    ];
    storeGetters.getConversationById.mockReturnValue({
      inbox_id: 4769,
      meta: { sender: { name: 'Client' } },
    });
    storeGetters.getInbox.mockReturnValue({ id: 4769, provider: 'sipuni' });

    const wrapper = mountComponent();
    const answerButton = wrapper.get('[aria-label="Call"]');

    expect(answerButton.attributes('disabled')).toBeDefined();
    await answerButton.trigger('click');
    expect(mockSession.joinCall).not.toHaveBeenCalled();
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

  it('keeps the current page after answering a call', async () => {
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

    expect(routerMock.push).not.toHaveBeenCalled();
  });

  it('keeps the current page when browser join falls back', async () => {
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

    expect(routerMock.push).not.toHaveBeenCalled();
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

  it('matches the incoming branch operator by SIP profile instead of the first candidate', () => {
    mockSession.incomingCalls = [
      {
        callSid: 'sipuni:branch-205',
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callDirection: 'inbound',
        fromNumber: '+770****1002',
        toNumber: '+770****1001',
        sipProfileId: 83,
        operatorCandidates: [
          {
            user_id: 5,
            name: 'Ahan',
            sip_profile_id: 82,
            internal_extension: '204',
          },
          {
            user_id: 6,
            name: 'Aset',
            sip_profile_id: 83,
            internal_extension: '205',
          },
        ],
        operatorInternalExtension: '205',
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

    expect(wrapper.text()).toContain('Aset (205)');
    expect(wrapper.text()).not.toContain('Ahan (205)');
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

  describe('inside the phone widget (embedded)', () => {
    const sipuniInbox = { id: 4769, name: 'Sipuni', provider: 'sipuni' };
    const activeCall = {
      callSid: 'active-call-1',
      conversationId: 724,
      inboxId: 4769,
      provider: 'sipuni',
      callDirection: 'inbound',
      fromNumber: '+77070001002',
      toNumber: '+77070001001',
      isActive: true,
      status: 'in_progress',
    };
    const ringingCall = {
      callSid: 'sipuni:ringing-1',
      conversationId: 725,
      inboxId: 4769,
      provider: 'sipuni',
      callDirection: 'inbound',
      status: 'ringing',
      fromNumber: '+77070001003',
      toNumber: '+77070001001',
    };
    const colleagueCall = {
      callSid: 'sipuni:colleague-1',
      conversationId: 726,
      inboxId: 4769,
      provider: 'sipuni',
      callDirection: 'inbound',
      status: 'in_progress',
      browserJoinSupported: false,
      browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
      operatorClaim: { user_id: 99, user_name: 'Ayan' },
    };

    beforeEach(() => {
      mockSession.formattedCallDuration = '00:00';
      storeGetters.getCurrentUser = { id: 1 };
      storeGetters.getInbox.mockReturnValue(sipuniInbox);
      storeGetters.getConversationById.mockImplementation(id => ({
        id,
        inbox_id: 4769,
        meta: { sender: { name: id === 724 ? 'Айгерим' : '+77070001003' } },
      }));
    });

    it('renders the calls in the phone instead of a floating window', () => {
      mockSession.incomingCalls = [ringingCall];

      const wrapper = mountComponent({ embedded: true });

      expect(wrapper.find('[data-testid="phone-widget-calls"]').exists()).toBe(
        true
      );
      expect(wrapper.find('[data-testid="floating-calls"]').exists()).toBe(
        false
      );
      expect(wrapper.find('.fixed').exists()).toBe(false);
      // The phone rings for the call it shows.
      expect(ringtoneState.sourceId).toBe('voice');
      expect(ringtoneState.isActive.value).toBe(true);
      wrapper.unmount();
    });

    it('keeps the standalone floating window for employees without a phone', () => {
      mockSession.incomingCalls = [ringingCall];

      const wrapper = mountComponent();

      expect(
        wrapper.find('[data-testid="floating-calls"]').classes()
      ).toContain('fixed');
      expect(wrapper.find('[data-testid="phone-widget-calls"]').exists()).toBe(
        false
      );
      wrapper.unmount();
    });

    it('hangs up the active call from the phone and shows the contact name', async () => {
      mockSession.hasActiveCall = true;
      mockSession.activeCall = activeCall;
      mockSession.formattedCallDuration = '01:05';

      const wrapper = mountComponent({ embedded: true });
      const card = wrapper.get('[data-testid="phone-widget-call-card"]');

      expect(card.attributes('data-own-call')).toBe('true');
      expect(card.get('[data-testid="phone-widget-call-name"]').text()).toBe(
        'Айгерим'
      );
      expect(card.text()).toContain('+77070001002→+77070001001');
      expect(card.text()).toContain('01:05');
      // The phone header owns the microphone and the hide button.
      expect(
        card.find('[data-testid="floating-call-microphone"]').exists()
      ).toBe(false);
      expect(card.find('[aria-label="Close"]').exists()).toBe(false);
      expect(card.find('[aria-label="Chat"]').exists()).toBe(true);

      await card.get('[aria-label="End call"]').trigger('click');

      expect(mockSession.endCall).toHaveBeenCalledWith({
        conversationId: 724,
        inboxId: 4769,
        provider: 'sipuni',
        callSid: 'active-call-1',
      });
      wrapper.unmount();
    });

    it('says on the own call that the microphone is off while the phone mutes it', async () => {
      microphoneState.available.value = true;
      mockSession.hasActiveCall = true;
      mockSession.activeCall = activeCall;
      mockSession.incomingCalls = [colleagueCall];

      const wrapper = mountComponent({ embedded: true });
      const ownCard = () =>
        wrapper.get(
          '[data-testid="phone-widget-call-card"][data-own-call="true"]'
        );
      const colleagueCard = () =>
        wrapper.get(
          '[data-testid="phone-widget-call-card"][data-own-call="false"]'
        );
      expect(
        ownCard().find('[data-testid="call-microphone-off"]').exists()
      ).toBe(false);

      microphoneState.muted.value = true;
      await wrapper.vm.$nextTick();

      const badge = ownCard().get('[data-testid="call-microphone-off"]');
      expect(badge.text()).toBe('PHONE_WIDGET.MICROPHONE_OFF');
      expect(badge.classes()).toEqual(
        expect.arrayContaining(['bg-n-ruby-9', 'text-white'])
      );
      expect(badge.find('.i-lucide-mic-off').exists()).toBe(true);
      // Only the employee's own connected call is muted.
      expect(
        colleagueCard().find('[data-testid="call-microphone-off"]').exists()
      ).toBe(false);

      microphoneState.muted.value = false;
      await wrapper.vm.$nextTick();
      expect(
        ownCard().find('[data-testid="call-microphone-off"]').exists()
      ).toBe(false);
      wrapper.unmount();
    });

    it('answers and declines a ringing call from the phone', async () => {
      mockSession.incomingCalls = [ringingCall];
      mockSession.joinCall.mockResolvedValue({ joinSupported: true });

      const wrapper = mountComponent({ embedded: true });
      const card = wrapper.get('[data-testid="phone-widget-call-card"]');

      // A number-only contact name is not repeated above the numbers.
      expect(card.find('[data-testid="phone-widget-call-name"]').exists()).toBe(
        false
      );
      expect(card.find('[aria-label="Close"]').exists()).toBe(false);

      await card.get('[aria-label="Call"]').trigger('click');
      await flushPromises();
      expect(mockSession.joinCall).toHaveBeenCalledWith(
        expect.objectContaining({
          callSid: 'sipuni:ringing-1',
          conversationId: 725,
          inboxId: 4769,
        })
      );

      await card.get('[aria-label="Reject"]').trigger('click');
      expect(mockSession.rejectIncomingCall).toHaveBeenCalledWith(ringingCall);
      wrapper.unmount();
    });

    it("keeps a colleague's call as a closable info card without call controls", async () => {
      mockSession.incomingCalls = [colleagueCall, ringingCall];

      const wrapper = mountComponent({ embedded: true });
      const cards = wrapper.findAll('[data-testid="phone-widget-call-card"]');

      expect(cards).toHaveLength(2);
      const [infoCard, ownCard] = cards;
      expect(infoCard.attributes('data-own-call')).toBe('false');
      expect(infoCard.text()).toContain('Handled by: Ayan');
      expect(infoCard.find('[aria-label="Call"]').exists()).toBe(false);
      expect(infoCard.find('[aria-label="End call"]').exists()).toBe(false);
      expect(ownCard.attributes('data-own-call')).toBe('true');
      expect(ownCard.find('[aria-label="Close"]').exists()).toBe(false);

      await infoCard.get('[aria-label="Close"]').trigger('click');

      expect(
        wrapper.findAll('[data-testid="phone-widget-call-card"]')
      ).toHaveLength(1);
      expect(wrapper.text()).not.toContain('Handled by: Ayan');
      wrapper.unmount();
    });
  });
});
