import { mount } from '@vue/test-utils';
import { computed, nextTick } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mockSession = vi.hoisted(() => ({
  activeCall: null,
  incomingCalls: [],
  hasActiveCall: false,
  isAccepting: false,
  isMuted: false,
  isOutboundRinging: false,
  isReconnecting: false,
  callError: '',
  formattedCallDuration: '00:00',
  acceptCall: vi.fn(),
  rejectCall: vi.fn(),
  endActiveCall: vi.fn(),
  toggleMute: vi.fn(),
  dismissIncomingCall: vi.fn(),
  startDurationTimer: vi.fn(),
}));

const ringtoneState = vi.hoisted(() => ({
  sourceId: null,
  isActive: null,
}));

const attentionState = vi.hoisted(() => ({ sourceId: null, calls: null }));

const voiceCallsState = vi.hoisted(() => ({ hasActiveCall: false }));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('shared/helpers/mitt', () => ({
  emitter: { on: vi.fn(), off: vi.fn(), emit: vi.fn() },
}));

vi.mock('dashboard/composables/useWhatsappCallSession', () => ({
  useWhatsappCallSession: () => ({
    activeCall: computed(() => mockSession.activeCall),
    incomingCalls: computed(() => mockSession.incomingCalls),
    hasActiveCall: computed(() => mockSession.hasActiveCall),
    isAccepting: computed(() => mockSession.isAccepting),
    isMuted: computed(() => mockSession.isMuted),
    isOutboundRinging: computed(() => mockSession.isOutboundRinging),
    isReconnecting: computed(() => mockSession.isReconnecting),
    callError: computed(() => mockSession.callError),
    formattedCallDuration: computed(() => mockSession.formattedCallDuration),
    acceptCall: mockSession.acceptCall,
    rejectCall: mockSession.rejectCall,
    endActiveCall: mockSession.endActiveCall,
    toggleMute: mockSession.toggleMute,
    dismissIncomingCall: mockSession.dismissIncomingCall,
    startDurationTimer: mockSession.startDurationTimer,
  }),
}));

vi.mock('dashboard/composables/useIncomingCallRingtone', () => ({
  useIncomingCallRingtone: (sourceId, isActive) => {
    ringtoneState.sourceId = sourceId;
    ringtoneState.isActive = isActive;
  },
}));

vi.mock('dashboard/composables/useIncomingCallAttention', () => ({
  useIncomingCallAttention: (sourceId, calls) => {
    attentionState.sourceId = sourceId;
    attentionState.calls = calls;
  },
}));

vi.mock('dashboard/stores/calls', () => ({
  useCallsStore: () => voiceCallsState,
}));

import WhatsappCallWidget from './WhatsappCallWidget.vue';

const mountComponent = () =>
  mount(WhatsappCallWidget, {
    global: {
      stubs: { Avatar: { template: '<div class="avatar" />' } },
    },
  });

describe('WhatsappCallWidget ringtone', () => {
  beforeEach(() => {
    mockSession.activeCall = null;
    mockSession.incomingCalls = [];
    mockSession.hasActiveCall = false;
    mockSession.isAccepting = false;
    mockSession.acceptCall.mockReset();
    voiceCallsState.hasActiveCall = false;
    ringtoneState.sourceId = null;
    ringtoneState.isActive = null;
    attentionState.sourceId = null;
    attentionState.calls = null;
  });

  it('reports a ringing WhatsApp call for the notification and the blinking tab', () => {
    mockSession.incomingCalls = [
      { callId: 'wa-incoming-attention', caller: { name: 'Customer' } },
      { callId: 'wa-incoming-number', caller: { phone: '+77070001003' } },
      { callId: 'wa-incoming-unknown', caller: {} },
    ];

    const wrapper = mountComponent();

    expect(attentionState.sourceId).toBe('whatsapp');
    expect(attentionState.calls.value).toEqual([
      { key: 'wa-incoming-attention', body: 'Customer · WhatsApp' },
      { key: 'wa-incoming-number', body: '+77070001003 · WhatsApp' },
      {
        key: 'wa-incoming-unknown',
        body: 'CONVERSATION.VOICE_WIDGET.UNKNOWN_CALLER · WhatsApp',
      },
    ]);
    wrapper.unmount();
  });

  it('reports nothing during a WhatsApp call or after the card is closed', async () => {
    mockSession.incomingCalls = [
      { callId: 'wa-incoming-quiet', caller: { name: 'Customer' } },
    ];
    const wrapper = mountComponent();
    expect(attentionState.calls.value).toHaveLength(1);

    await wrapper.get('[aria-label="WHATSAPP_CALL.CLOSE"]').trigger('click');
    await nextTick();
    expect(attentionState.calls.value).toEqual([]);
    wrapper.unmount();

    mockSession.hasActiveCall = true;
    mockSession.activeCall = { callId: 'wa-active', caller: { name: 'Mine' } };
    const busy = mountComponent();
    expect(attentionState.calls.value).toEqual([]);
    busy.unmount();
  });

  it('rings for a visible incoming WhatsApp call', () => {
    mockSession.incomingCalls = [
      { callId: 'wa-incoming-1', caller: { name: 'Customer' } },
    ];

    const wrapper = mountComponent();

    expect(ringtoneState.sourceId).toBe('whatsapp');
    expect(ringtoneState.isActive.value).toBe(true);
    wrapper.unmount();
  });

  it('does not ring while a WhatsApp call is active', () => {
    mockSession.hasActiveCall = true;
    mockSession.activeCall = {
      callId: 'wa-active-1',
      caller: { name: 'Customer' },
    };
    mockSession.incomingCalls = [
      { callId: 'wa-incoming-2', caller: { name: 'Another customer' } },
    ];

    const wrapper = mountComponent();

    expect(ringtoneState.isActive.value).toBe(false);
    wrapper.unmount();
  });

  it('keeps incoming WhatsApp visible but blocks accept while voice is active', async () => {
    voiceCallsState.hasActiveCall = true;
    mockSession.incomingCalls = [
      { callId: 'wa-incoming-busy', caller: { name: 'Customer' } },
    ];

    const wrapper = mountComponent();
    const acceptButton = wrapper.get('[title="WHATSAPP_CALL.ACCEPT"]');

    expect(wrapper.text()).toContain('Customer');
    expect(acceptButton.attributes('disabled')).toBeDefined();
    expect(ringtoneState.isActive.value).toBe(false);
    await acceptButton.trigger('click');
    expect(mockSession.acceptCall).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it('tells the employee on a call that he cannot take a second WhatsApp call', () => {
    mockSession.incomingCalls = [
      { callId: 'wa-incoming-note', caller: { name: 'Customer' } },
    ];
    const idle = mountComponent();
    expect(idle.find('[data-testid="whatsapp-call-busy-note"]').exists()).toBe(
      false
    );
    idle.unmount();

    voiceCallsState.hasActiveCall = true;
    const busy = mountComponent();
    expect(busy.get('[data-testid="whatsapp-call-busy-note"]').text()).toBe(
      'CONVERSATION.VOICE_WIDGET.BUSY_ON_CALL'
    );
    busy.unmount();
  });

  it('silences the ringtone when the incoming card is closed', async () => {
    mockSession.incomingCalls = [
      { callId: 'wa-incoming-3', caller: { name: 'Customer' } },
    ];
    const wrapper = mountComponent();

    await wrapper.get('[aria-label="WHATSAPP_CALL.CLOSE"]').trigger('click');
    await nextTick();

    expect(ringtoneState.isActive.value).toBe(false);
    wrapper.unmount();
  });
});

describe('WhatsappCallWidget microphone', () => {
  const mountActiveCall = isMuted => {
    mockSession.hasActiveCall = true;
    mockSession.activeCall = {
      callId: 'wa-active-mic',
      caller: { name: 'Customer' },
    };
    mockSession.incomingCalls = [];
    mockSession.isMuted = isMuted;
    return mountComponent();
  };
  const microphoneButton = wrapper =>
    wrapper.get('[data-testid="whatsapp-call-microphone"]');

  beforeEach(() => {
    mockSession.toggleMute.mockReset();
    voiceCallsState.hasActiveCall = false;
  });

  it('offers to mute a live microphone as an unpressed button', async () => {
    const wrapper = mountActiveCall(false);
    const microphone = microphoneButton(wrapper);

    expect(microphone.attributes('aria-pressed')).toBe('false');
    expect(microphone.attributes('aria-label')).toBe(
      'PHONE_WIDGET.MUTE_MICROPHONE'
    );
    expect(microphone.attributes('title')).toBe('PHONE_WIDGET.MUTE_MICROPHONE');
    expect(microphone.classes()).not.toContain('bg-n-ruby-9');
    expect(microphone.find('.i-ph-microphone-bold').exists()).toBe(true);
    expect(wrapper.find('[data-testid="call-microphone-off"]').exists()).toBe(
      false
    );

    await microphone.trigger('click');
    expect(mockSession.toggleMute).toHaveBeenCalledOnce();
    wrapper.unmount();
  });

  it('shows a muted microphone as a filled red pressed button and says so', () => {
    const wrapper = mountActiveCall(true);
    const microphone = microphoneButton(wrapper);

    expect(microphone.attributes('aria-pressed')).toBe('true');
    expect(microphone.classes()).toEqual(
      expect.arrayContaining(['bg-n-ruby-9', 'text-white'])
    );
    expect(microphone.attributes('aria-label')).toBe(
      'PHONE_WIDGET.MICROPHONE_MUTED'
    );
    expect(microphone.attributes('title')).toBe(
      'PHONE_WIDGET.MICROPHONE_MUTED'
    );
    expect(microphone.find('.i-ph-microphone-slash-bold').exists()).toBe(true);
    expect(wrapper.get('[data-testid="call-microphone-off"]').text()).toBe(
      'PHONE_WIDGET.MICROPHONE_OFF'
    );
    wrapper.unmount();
  });
});
