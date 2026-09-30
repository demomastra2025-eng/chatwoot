import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import { createPinia, setActivePinia } from 'pinia';
import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';
import PhoneWidget from './PhoneWidget.vue';

// The phone widget together with its real call list: the employee's calls are
// answered, declined and hung up inside the one phone window.
const { state, session, values, settingsState, ringtone, routerMock } =
  await vi.hoisted(async () => {
    const { reactive } = await import('vue');
    return {
      state: reactive({
        activeCall: null,
        hasActiveCall: false,
        hasIncomingCall: false,
        incomingCalls: [],
      }),
      session: {
        joinCall: vi.fn(),
        endCall: vi.fn(),
        rejectIncomingCall: vi.fn(),
      },
      values: {
        'inboxes/getInboxes': [],
        getCurrentAccountId: 1,
        getCurrentUser: { id: 1, name: 'Иван Иванов' },
      },
      settingsState: { settings: null, update: vi.fn() },
      ringtone: { active: null, mounted: 0 },
      routerMock: { currentRoute: null, push: vi.fn() },
    };
  });

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: {
    sessions: {
      'sip_profile:83': {
        provider: 'sipuni',
        inboxId: 43,
        sipProfileId: 83,
        sessionKey: 'sip_profile:83',
        callingSupported: true,
        registered: true,
      },
    },
    bootstrapIncomingSupport: vi.fn(() => Promise.resolve()),
    initializeDevice: vi.fn(() => Promise.resolve()),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/stores/calls', async importOriginal => ({
  ...(await importOriginal()),
  useCallsStore: () => state,
}));
vi.mock('dashboard/stores/whatsappCalls', () => ({
  useWhatsappCallsStore: () => ({ hasActiveCall: false, isAccepting: false }),
}));
vi.mock('dashboard/composables/useCallSession', async () => {
  const { computed } = await vi.importActual('vue');
  return {
    useCallSession: () => ({
      activeCall: computed(() => state.activeCall),
      incomingCalls: computed(() => state.incomingCalls),
      hasActiveCall: computed(() => state.hasActiveCall),
      isJoining: computed(() => false),
      canHandleCallInBrowser: call => call?.browserJoinSupported !== false,
      isIncomingCallActionableInBrowser: call =>
        call?.callDirection === 'inbound' && call?.status === 'ringing',
      joinCall: session.joinCall,
      endCall: session.endCall,
      rejectIncomingCall: session.rejectIncomingCall,
      formattedCallDuration: computed(() => '00:42'),
    }),
  };
});
vi.mock('dashboard/composables/useIncomingCallRingtone', async () => {
  const { onUnmounted } = await vi.importActual('vue');
  return {
    useIncomingCallRingtone: (_sourceId, isActive) => {
      ringtone.active = isActive;
      ringtone.mounted += 1;
      onUnmounted(() => {
        ringtone.mounted -= 1;
      });
    },
  };
});
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: settingsState.settings,
    updateUISettings: settingsState.update,
  }),
}));
vi.mock('dashboard/composables/useSipMicrophone', async () => {
  const { ref: makeRef } = await vi.importActual('vue');
  return {
    useSipMicrophone: () => ({
      microphoneAvailable: makeRef(true),
      microphoneMuted: makeRef(false),
      toggleMicrophone: vi.fn(),
    }),
  };
});
vi.mock('dashboard/composables/store', async () => {
  const { computed } = await vi.importActual('vue');
  return {
    useMapGetter: getter => computed(() => values[getter]),
  };
});
vi.mock('vue-router', async () => {
  const { ref: makeRef } = await vi.importActual('vue');
  routerMock.currentRoute = makeRef({
    params: { accountId: 1 },
    query: {},
    name: 'home',
  });
  return { useRouter: () => routerMock };
});
vi.mock('vuex', () => ({
  useStore: () => ({
    getters: {
      getConversationById: id => ({
        id,
        inbox_id: 43,
        meta: { sender: { name: 'Айгерим' } },
      }),
      'inboxes/getInbox': () => ({
        id: 43,
        name: 'Line 43',
        provider: 'sipuni',
        channel_type: 'Channel::Voice',
      }),
      getSelectedChat: null,
      getCurrentUser: values.getCurrentUser,
    },
  }),
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const ringingCall = {
  callSid: 'sipuni:incoming-1',
  conversationId: 501,
  inboxId: 43,
  provider: 'sipuni',
  callDirection: 'inbound',
  status: 'ringing',
  fromNumber: '+77010000001',
  toNumber: '+77270000000',
};
const connectedCall = {
  ...ringingCall,
  status: 'in_progress',
  isActive: true,
};

// Every mounted phone shares the mocked call state: unmount them after each
// test so an earlier phone never reacts to a later test's calls.
let mountedPhones = [];
const mountPhone = () => {
  const wrapper = mount(PhoneWidget, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        VoiceCallButton: true,
        Avatar: { template: '<span class="avatar" />' },
      },
    },
  });
  mountedPhones.push(wrapper);
  return wrapper;
};
const panel = wrapper => wrapper.find('[data-testid="phone-widget-panel"]');
// Hiding keeps the phone and its call list mounted, only off screen.
const phoneShown = wrapper => {
  const phone = wrapper.find('[data-testid="phone-widget"]');
  return phone.exists() && phone.element.style.display !== 'none';
};

describe('PhoneWidget with its calls', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    values['inboxes/getInboxes'] = [
      {
        id: 43,
        name: 'Line 43',
        channel_type: 'Channel::Voice',
        provider: 'sipuni',
      },
    ];
    settingsState.settings = ref({});
    settingsState.update.mockReset().mockImplementation(next => {
      settingsState.settings.value = {
        ...settingsState.settings.value,
        ...next,
      };
    });
    state.activeCall = null;
    state.hasActiveCall = false;
    state.hasIncomingCall = false;
    state.incomingCalls = [];
    session.joinCall.mockReset().mockResolvedValue({ joinSupported: true });
    session.endCall.mockReset().mockResolvedValue();
    session.rejectIncomingCall.mockReset();
    routerMock.push.mockReset();
    ringtone.active = null;
    ringtone.mounted = 0;
  });

  afterEach(() => {
    mountedPhones.forEach(wrapper => wrapper.unmount());
    mountedPhones = [];
  });

  it('hangs up the connected call from the phone itself, with no second call window', async () => {
    state.activeCall = connectedCall;
    state.hasActiveCall = true;
    const wrapper = mountPhone();
    await flushPromises();

    expect(wrapper.findAll('[data-testid="phone-widget-panel"]')).toHaveLength(
      1
    );
    expect(wrapper.find('[data-testid="floating-calls"]').exists()).toBe(false);
    const card = panel(wrapper).get('[data-testid="phone-widget-call-card"]');
    expect(card.text()).toContain('Айгерим');
    expect(card.text()).toContain('00:42');
    expect(
      panel(wrapper).get('[data-testid="phone-widget-dialer"]').element.style
        .display
    ).toBe('none');

    await card
      .get('[aria-label="CONVERSATION.VOICE_WIDGET.END_CALL"]')
      .trigger('click');

    expect(session.endCall).toHaveBeenCalledWith({
      conversationId: 501,
      inboxId: 43,
      provider: 'sipuni',
      callSid: 'sipuni:incoming-1',
    });
  });

  it('pops a hidden phone for a ringing call with answer, decline and chat inside it', async () => {
    settingsState.settings.value = {
      phone_widget_hidden_accounts: { 1: true },
    };
    const wrapper = mountPhone();
    await flushPromises();
    expect(phoneShown(wrapper)).toBe(false);
    expect(ringtone.active.value).toBe(false);

    state.incomingCalls = [ringingCall];
    state.hasIncomingCall = true;
    await flushPromises();

    const card = panel(wrapper).get('[data-testid="phone-widget-call-card"]');
    expect(phoneShown(wrapper)).toBe(true);
    expect(ringtone.active.value).toBe(true);

    await card
      .get('[aria-label="CONVERSATION.VOICE_WIDGET.OPEN_CHAT"]')
      .trigger('click');
    expect(routerMock.push).toHaveBeenCalledWith({
      name: 'conversation_through_inbox',
      params: { accountId: 1, conversation_id: 501, inbox_id: 43 },
    });

    await card
      .get('[aria-label="CONVERSATION.VOICE_WIDGET.CALL"]')
      .trigger('click');
    await flushPromises();
    expect(session.joinCall).toHaveBeenCalledWith(
      expect.objectContaining({ callSid: 'sipuni:incoming-1', inboxId: 43 })
    );

    await card
      .get('[aria-label="CONVERSATION.VOICE_WIDGET.REJECT_CALL"]')
      .trigger('click');
    expect(session.rejectIncomingCall).toHaveBeenCalledWith(ringingCall);
  });

  it('stops presenting the call (and its ringtone) when the employee hides the phone', async () => {
    const wrapper = mountPhone();
    await flushPromises();
    state.incomingCalls = [ringingCall];
    state.hasIncomingCall = true;
    await flushPromises();
    expect(ringtone.mounted).toBe(1);

    await wrapper.get('[data-testid="phone-widget-hide"]').trigger('click');

    expect(phoneShown(wrapper)).toBe(false);
    // The call list stays mounted so its call session keeps listening for
    // SIP INVITEs, but a hidden phone never rings.
    expect(ringtone.mounted).toBe(1);
    expect(ringtone.active.value).toBe(false);
    expect(usePhoneWidgetStore().callDismissed).toBe(true);
    // Hiding never touches the call itself.
    expect(session.rejectIncomingCall).not.toHaveBeenCalled();
    expect(session.endCall).not.toHaveBeenCalled();
  });
});
