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
    ringtoneState.sourceId = null;
    ringtoneState.isActive = null;
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
