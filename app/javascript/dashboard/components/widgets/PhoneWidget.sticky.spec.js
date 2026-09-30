/* eslint-disable no-await-in-loop */
import { flushPromises, mount } from '@vue/test-utils';
import { defineComponent, h, ref, nextTick } from 'vue';
import { createPinia, setActivePinia } from 'pinia';
import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';
import PhoneWidget from './PhoneWidget.vue';
import FloatingCallWidget from './FloatingCallWidget.vue';

const { state, values, settingsState, wp, counters } = await vi.hoisted(
  async () => {
    const { reactive } = await import('vue');
    const listeners = {};
    return {
      state: reactive({
        activeCall: null,
        hasActiveCall: false,
        hasIncomingCall: false,
        incomingCalls: [],
      }),
      values: reactive({
        'inboxes/getInboxes': [],
        getCurrentAccountId: 1,
        getCurrentUser: { id: 1, name: 'Ivan' },
      }),
      settingsState: { settings: null, update: vi.fn() },
      counters: { mounted: 0, unmounted: 0 },
      wp: {
        sessions: {},
        bootstrapIncomingSupport: vi.fn(() => Promise.resolve()),
        initializeDevice: vi.fn(() => Promise.resolve()),
        addEventListener: vi.fn((e, cb) => {
          if (!listeners[e]) listeners[e] = new Set();
          listeners[e].add(cb);
        }),
        removeEventListener: vi.fn((e, cb) => {
          if (listeners[e]) listeners[e].delete(cb);
        }),
        emit: (e, detail) =>
          [...(listeners[e] || [])].forEach(cb => cb({ detail })),
        count: e => (listeners[e] ? listeners[e].size : 0),
      },
    };
  }
);

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({ default: wp }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/stores/calls', async importOriginal => ({
  ...(await importOriginal()),
  useCallsStore: () => state,
}));
vi.mock('dashboard/stores/whatsappCalls', () => ({
  useWhatsappCallsStore: () => ({ hasActiveCall: false, isAccepting: false }),
}));
// Stand-in for useCallSession: counts mounts, bootstraps (token fetch) on
// mount and reports browser INVITEs into the calls store like the real one.
vi.mock('dashboard/composables/useCallSession', async () => {
  const { computed, onMounted, onUnmounted } = await vi.importActual('vue');
  return {
    useCallSession: () => {
      const onIncoming = event => {
        state.incomingCalls = [...state.incomingCalls, event.detail];
        state.hasIncomingCall = true;
      };
      onMounted(() => {
        counters.mounted += 1;
        wp.addEventListener('call:incoming', onIncoming);
        wp.bootstrapIncomingSupport();
      });
      onUnmounted(() => {
        counters.unmounted += 1;
        wp.removeEventListener('call:incoming', onIncoming);
      });
      return {
        activeCall: computed(() => state.activeCall),
        incomingCalls: computed(() => state.incomingCalls),
        hasActiveCall: computed(() => state.hasActiveCall),
        isJoining: computed(() => false),
        canHandleCallInBrowser: () => true,
        isIncomingCallActionableInBrowser: call =>
          call?.callDirection === 'inbound' && call?.status === 'ringing',
        joinCall: vi.fn(),
        endCall: vi.fn(),
        rejectIncomingCall: vi.fn(),
        formattedCallDuration: computed(() => '00:01'),
      };
    },
  };
});
vi.mock('dashboard/composables/useIncomingCallRingtone', () => ({
  useIncomingCallRingtone: () => {},
}));
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
  return { useMapGetter: getter => computed(() => values[getter]) };
});
vi.mock('vue-router', async () => {
  const { ref: makeRef } = await vi.importActual('vue');
  const currentRoute = makeRef({
    params: { accountId: 1 },
    query: {},
    name: 'home',
  });
  return { useRouter: () => ({ currentRoute, push: vi.fn() }) };
});
vi.mock('vuex', () => ({
  useStore: () => ({
    getters: {
      getConversationById: id => ({
        id,
        inbox_id: 43,
        meta: { sender: { name: 'Aigerim' } },
      }),
      'inboxes/getInbox': () => ({
        id: 43,
        name: 'Line 43',
        provider: 'sipuni',
        channel_type: 'Channel::Voice',
      }),
      getSelectedChat: null,
      getCurrentUser: { id: 1, name: 'Ivan' },
    },
  }),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const session = () => ({
  provider: 'sipuni',
  inboxId: 43,
  sipProfileId: 83,
  sessionKey: 'sip_profile:83',
  callingSupported: true,
  registered: true,
});
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
const voiceInbox = {
  id: 43,
  name: 'Line 43',
  channel_type: 'Channel::Voice',
  provider: 'sipuni',
};

// Dashboard.vue: <FloatingCallWidget v-if="showStandaloneCallCards" /> <PhoneWidget />
const Harness = defineComponent({
  setup() {
    const store = usePhoneWidgetStore();
    return () =>
      h('div', [
        store.available ? null : h(FloatingCallWidget),
        h(PhoneWidget),
      ]);
  },
});
const mountHarness = () =>
  mount(Harness, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        VoiceCallButton: true,
        Avatar: { template: '<span class="avatar" />' },
      },
    },
  });
const phone = w => w.find('[data-testid="phone-widget"]');
const shownEl = el => {
  for (let n = el; n; n = n.parentElement) {
    if (n.style && n.style.display === 'none') return false;
  }
  return true;
};
const phoneShown = w => phone(w).exists() && shownEl(phone(w).element);
// Any mounted call list (embedded or standalone) showing the ringing call on screen.
const callOnScreen = w =>
  w
    .findAllComponents(FloatingCallWidget)
    .some(c => shownEl(c.element) && /Aigerim|77010000001/.test(c.text()));

const live = () => counters.mounted - counters.unmounted;
let wrapper;

describe('PhoneWidget keeps call cards mounted while a line re-registers', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    values['inboxes/getInboxes'] = [voiceInbox];
    values.getCurrentAccountId = 1;
    settingsState.settings = ref({});
    settingsState.update.mockReset().mockImplementation(next => {
      settingsState.settings.value = {
        ...settingsState.settings.value,
        ...next,
      };
    });
    Object.keys(wp.sessions).forEach(k => delete wp.sessions[k]);
    wp.sessions['sip_profile:83'] = session();
    wp.bootstrapIncomingSupport.mockClear();
    counters.mounted = 0;
    counters.unmounted = 0;
    state.activeCall = null;
    state.hasActiveCall = false;
    state.hasIncomingCall = false;
    state.incomingCalls = [];
  });
  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    vi.useRealTimers();
  });

  it('A: >15s empty sessions and back: one call session mounted, no extra token fetch', async () => {
    wrapper = mountHarness();
    await flushPromises();
    const base = {
      ...counters,
      boots: wp.bootstrapIncomingSupport.mock.calls.length,
    };
    expect(usePhoneWidgetStore().available).toBe(true);
    expect(live()).toBe(1);
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
    for (let i = 0; i < 3; i += 1) {
      delete wp.sessions['sip_profile:83'];
      wp.emit('call:sessions-changed');
      await nextTick();
      vi.advanceTimersByTime(20_000);
      await flushPromises();
      expect(usePhoneWidgetStore().available).toBe(true);
      expect(phone(wrapper).exists()).toBe(true);
      expect(phoneShown(wrapper)).toBe(false);
      expect(live()).toBe(1);
      wp.sessions['sip_profile:83'] = session();
      wp.emit('call:sessions-changed');
      await flushPromises();
      expect(phoneShown(wrapper)).toBe(true);
    }
    expect(counters.mounted).toBe(base.mounted);
    expect(counters.unmounted).toBe(base.unmounted);
    expect(wp.bootstrapIncomingSupport.mock.calls.length).toBe(base.boots);
    expect(wp.count('call:incoming')).toBe(1);
  });

  it('B1: browser INVITE while the line is re-registering (session back) pops the phone', async () => {
    wrapper = mountHarness();
    await flushPromises();
    settingsState.settings.value = {
      phone_widget_hidden_accounts: { 1: true },
    };
    await flushPromises();
    expect(phoneShown(wrapper)).toBe(false);
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
    delete wp.sessions['sip_profile:83'];
    wp.emit('call:sessions-changed');
    vi.advanceTimersByTime(20_000);
    await flushPromises();
    wp.sessions['sip_profile:83'] = session();
    wp.emit('call:sessions-changed');
    wp.emit('call:incoming', ringingCall);
    await flushPromises();
    expect(state.incomingCalls.length).toBe(1);
    expect(phoneShown(wrapper)).toBe(true);
    expect(callOnScreen(wrapper)).toBe(true);
  });

  it('B2: INVITE reported while live sessions are still empty (>15s gap) is on screen', async () => {
    wrapper = mountHarness();
    await flushPromises();
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
    delete wp.sessions['sip_profile:83'];
    wp.emit('call:sessions-changed');
    vi.advanceTimersByTime(20_000);
    await flushPromises();
    wp.emit('call:incoming', ringingCall);
    await flushPromises();
    expect(state.incomingCalls.length).toBe(1);
    expect(callOnScreen(wrapper)).toBe(true);
  });

  it('B3: server-reported ringing call (calls store) during >15s gap is on screen', async () => {
    wrapper = mountHarness();
    await flushPromises();
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
    delete wp.sessions['sip_profile:83'];
    wp.emit('call:sessions-changed');
    vi.advanceTimersByTime(20_000);
    await flushPromises();
    state.incomingCalls = [ringingCall];
    state.hasIncomingCall = true;
    await flushPromises();
    expect(callOnScreen(wrapper)).toBe(true);
  });

  it('D: no voice inbox -> no phone, standalone cards', async () => {
    values['inboxes/getInboxes'] = [];
    wrapper = mountHarness();
    await flushPromises();
    expect(usePhoneWidgetStore().available).toBe(false);
    expect(phone(wrapper).exists()).toBe(false);
    expect(live()).toBe(1);
    state.incomingCalls = [ringingCall];
    await flushPromises();
    expect(callOnScreen(wrapper)).toBe(true);
  });

  it('E: voice inboxes but no browser line -> no phone, standalone cards', async () => {
    delete wp.sessions['sip_profile:83'];
    wrapper = mountHarness();
    await flushPromises();
    expect(usePhoneWidgetStore().available).toBe(false);
    expect(phone(wrapper).exists()).toBe(false);
    expect(live()).toBe(1);
  });

  it('F1: account loses all voice inboxes -> phone unmounts, standalone cards back', async () => {
    wrapper = mountHarness();
    await flushPromises();
    values['inboxes/getInboxes'] = [];
    await flushPromises();
    expect(usePhoneWidgetStore().available).toBe(false);
    expect(phone(wrapper).exists()).toBe(false);
    expect(live()).toBe(1);
  });

  it('F2: account change (new account inboxes, sessions re-bootstrapped) -> phone back', async () => {
    wrapper = mountHarness();
    await flushPromises();
    delete wp.sessions['sip_profile:83'];
    values.getCurrentAccountId = 2;
    values['inboxes/getInboxes'] = [{ ...voiceInbox, id: 44 }];
    wp.bootstrapIncomingSupport.mockImplementationOnce(() => {
      wp.sessions['sip_profile:84'] = {
        ...session(),
        inboxId: 44,
        sipProfileId: 84,
        sessionKey: 'sip_profile:84',
      };
      return Promise.resolve();
    });
    await flushPromises();
    expect(usePhoneWidgetStore().available).toBe(true);
    expect(phoneShown(wrapper)).toBe(true);
  });

  it('F3: accountId changes while the same line stays live -> phone should stay', async () => {
    wrapper = mountHarness();
    await flushPromises();
    values.getCurrentAccountId = 2;
    await flushPromises();
    expect(usePhoneWidgetStore().available).toBe(true);
  });
});
