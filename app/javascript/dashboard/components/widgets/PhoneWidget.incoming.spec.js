/* eslint-disable max-classes-per-file, class-methods-use-this */
// The phone with the real WebphoneClient, Janus SIP client, call session and
// call list; only Janus, the API and the UI settings are faked. A SIP INVITE
// must reach the operator whether the phone is on screen or hidden.
import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const {
  pluginSendMock,
  pluginState,
  api,
  values,
  settingsState,
  ringtone,
  routerMock,
} = await vi.hoisted(async () => {
  const { reactive } = await import('vue');
  return {
    pluginSendMock: vi.fn(),
    pluginState: { options: null },
    api: {
      token: vi.fn(),
      presence: vi.fn(),
      reportIncoming: vi.fn(),
    },
    values: reactive({
      'inboxes/getInboxes': [],
      getCurrentAccountId: 5118,
      getCurrentUser: { id: 137, name: 'Оператор' },
    }),
    settingsState: { settings: null, update: vi.fn() },
    ringtone: { sources: new Set() },
    routerMock: { currentRoute: null, push: vi.fn() },
  };
});

vi.mock('webrtc-adapter', () => ({
  default: { browserDetails: { browser: 'chrome' } },
  browserDetails: { browser: 'chrome' },
}));

vi.mock('janus-gateway', () => {
  class JanusMock {
    constructor(options = {}) {
      this.options = options;
      window.setTimeout(() => options.success?.(), 0);
    }

    attach(options = {}) {
      pluginState.options = options;
      options.success?.({
        send: pluginSendMock,
        detach: vi.fn(),
        hangup: vi.fn(),
        createOffer: offerOptions =>
          offerOptions?.success?.({ type: 'offer', sdp: 'mock-sdp' }),
        createAnswer: answerOptions =>
          answerOptions?.success?.({ type: 'answer', sdp: 'mock-answer' }),
      });
    }

    destroy() {
      this.options.destroyed?.();
    }
  }

  JanusMock.initDone = false;
  JanusMock.init = vi.fn(({ callback }) => {
    JanusMock.initDone = true;
    callback?.();
  });
  JanusMock.attachMediaStream = vi.fn();

  return { default: JanusMock };
});

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    getWebphoneToken: api.token,
    getNativeWebphoneToken: api.token,
    updateWebphonePresence: api.presence,
    updateWebphonePresenceOnUnload: vi.fn(() => Promise.resolve(null)),
    reportBrowserSipIncoming: api.reportIncoming,
    rejectIncomingCall: vi.fn(() => Promise.resolve({})),
    claimIncomingCall: vi.fn(() => Promise.resolve({})),
    uploadWebphoneRecording: vi.fn(() => Promise.resolve({})),
  },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: settingsState.settings,
    updateUISettings: settingsState.update,
  }),
}));
vi.mock('dashboard/composables/useIncomingCallRingtone', async () => {
  const { onUnmounted } = await vi.importActual('vue');
  return {
    useIncomingCallRingtone: (_sourceId, isActive) => {
      ringtone.sources.add(isActive);
      onUnmounted(() => ringtone.sources.delete(isActive));
    },
  };
});
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
  routerMock.currentRoute = makeRef({
    params: { accountId: 5118 },
    query: {},
    name: 'home',
  });
  return {
    useRouter: () => routerMock,
    useRoute: () => routerMock.currentRoute.value,
  };
});
vi.mock('vuex', () => ({
  useStore: () => ({
    getters: {
      getConversationById: () => null,
      'inboxes/getInbox': () => ({
        id: 5248,
        name: 'SEZIM',
        provider: 'sipuni',
        channel_type: 'Channel::Voice',
      }),
      getSelectedChat: null,
      getCurrentUser: values.getCurrentUser,
    },
  }),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const { default: WebphoneClient } = await import(
  'dashboard/api/channel/voice/webphoneClient'
);
const { default: PhoneWidget } = await import('./PhoneWidget.vue');

const SESSION_KEY = 'sip_profile:146';
let ticket = 0;
let registrationInstance = 'lease-1';
const tokenResponse = () => {
  ticket += 1;
  return {
    provider: 'sipuni',
    callingSupported: true,
    browserJoinSupported: true,
    janusServer: `wss://dev.example.test/janus-sipuni?janus_ticket=t${ticket}`,
    session_key: SESSION_KEY,
    sip_profile_id: 146,
    registration_config_version: 'config-1',
    registration_instance_id: registrationInstance,
    account_id: 5118,
    inbox_id: 5248,
    sip: {
      username: '990001000018',
      password: 'test-sip-password',
      host: 'ats01.kz.sipuni.com',
      internalExtension: '201',
    },
  };
};

const hiddenSettings = () => ({ phone_widget_hidden_accounts: { 5118: true } });
const settle = () => vi.advanceTimersByTimeAsync(50);
const isRinging = () => [...ringtone.sources].some(active => active.value);
const phone = wrapper => wrapper.find('[data-testid="phone-widget"]');
const phoneOnScreen = wrapper =>
  phone(wrapper).exists() && phone(wrapper).isVisible();

const deliverInvite = (callId = 'janus-invite-1') =>
  pluginState.options?.onmessage?.(
    {
      call_id: callId,
      result: {
        event: 'incomingcall',
        call_id: callId,
        username: 'sip:+77010000001@ats01.kz.sipuni.com',
      },
    },
    { type: 'offer', sdp: 'remote-offer-sdp' }
  );

let wrapper = null;
const mountPhone = async () => {
  wrapper = mount(PhoneWidget, {
    attachTo: document.body,
    global: {
      mocks: { $t: key => key },
      stubs: {
        VoiceCallButton: true,
        Avatar: { template: '<span class="avatar" />' },
      },
    },
  });
  await settle();
  expect(WebphoneClient.sessions[SESSION_KEY]?.registered).toBe(true);
  return wrapper;
};

describe('PhoneWidget: browser SIP incoming calls reach the operator', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    setActivePinia(createPinia());
    ticket = 0;
    registrationInstance = 'lease-1';
    Object.assign(WebphoneClient, {
      sessions: {},
      providerSessions: {},
      nativeSipClients: {},
      nativeSipClientGenerations: {},
      nativeSessionConfigs: {},
      nativeSessionRetryTimers: {},
      nativeSessionRetryState: {},
      nativeSessionRetryPromises: {},
      deviceInitializationPromises: {},
      bootstrapIncomingPromise: null,
      activeProvider: null,
      activeSessionKey: null,
    });
    values['inboxes/getInboxes'] = [
      {
        id: 5248,
        name: 'SEZIM',
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
    pluginSendMock.mockReset().mockImplementation(({ message } = {}) => {
      if (message?.request === 'register') {
        window.setTimeout(() => {
          pluginState.options?.onmessage?.({ result: { event: 'registered' } });
        }, 0);
      }
    });
    api.token
      .mockReset()
      .mockImplementation(() => Promise.resolve(tokenResponse()));
    api.presence.mockReset().mockImplementation(() =>
      Promise.resolve({
        presence_update_accepted: true,
        registered_for_routing: true,
      })
    );
    api.reportIncoming.mockReset().mockImplementation(payload =>
      Promise.resolve({
        call_sid: 'sipuni:incoming-1',
        status: 'ringing',
        conversation_id: 501,
        inbox_id: 5248,
        provider: 'sipuni',
        call_direction: 'inbound',
        from_number: '+77010000001',
        janus_call_ref: payload.call_ref,
        janus_session_key: payload.session_key,
        sip_profile_id: 146,
        browser_join_supported: true,
      })
    );
  });

  afterEach(async () => {
    wrapper?.unmount();
    wrapper = null;
    await WebphoneClient.destroyDevice({ provider: 'sipuni' });
    vi.useRealTimers();
  });

  it('shows the phone to an operator who never hid it and rings on an INVITE', async () => {
    await mountPhone();
    expect(phoneOnScreen(wrapper)).toBe(true);

    deliverInvite();
    await settle();

    expect(api.reportIncoming).toHaveBeenCalledTimes(1);
    expect(api.reportIncoming).toHaveBeenCalledWith(
      expect.objectContaining({
        provider: 'sipuni',
        call_ref: 'janus-invite-1',
        registration_instance_id: 'lease-1',
      })
    );
    expect(phone(wrapper).attributes('data-state')).toBe('incoming');
    expect(isRinging()).toBe(true);
  });

  it('reports an INVITE that arrives while the phone is hidden, then pops the phone and rings', async () => {
    settingsState.settings.value = hiddenSettings();
    await mountPhone();
    expect(phoneOnScreen(wrapper)).toBe(false);
    expect(isRinging()).toBe(false);

    deliverInvite();
    await settle();

    // Without the report the server never learns the browser leg rang
    // (a one-leg call session) and nothing shows the call to the operator.
    expect(api.reportIncoming).toHaveBeenCalledTimes(1);
    expect(phoneOnScreen(wrapper)).toBe(true);
    expect(phone(wrapper).attributes('data-state')).toBe('incoming');
    expect(isRinging()).toBe(true);
    // Hiding never touched the SIP registration.
    expect(WebphoneClient.sessions[SESSION_KEY].registered).toBe(true);
  });

  it('reports an INVITE on the new registration after a hidden phone re-registers', async () => {
    settingsState.settings.value = hiddenSettings();
    await mountPhone();

    // The server hands out a new registration instance (as seen on PROD every
    // few minutes): the Janus SIP handle is replaced and registers again.
    registrationInstance = 'lease-2';
    const reRegistration = WebphoneClient.initializeDevice(5248, {
      native: true,
    });
    await settle();
    await reRegistration;
    expect(WebphoneClient.sessions[SESSION_KEY].registered).toBe(true);

    deliverInvite('janus-invite-2');
    await settle();

    expect(api.reportIncoming).toHaveBeenCalledTimes(1);
    expect(api.reportIncoming).toHaveBeenCalledWith(
      expect.objectContaining({ call_ref: 'janus-invite-2' })
    );
    expect(phoneOnScreen(wrapper)).toBe(true);
    expect(isRinging()).toBe(true);
  });

  it('stops ringing when the operator hides a ringing call and pops again for the next call', async () => {
    await mountPhone();
    deliverInvite();
    await settle();
    expect(isRinging()).toBe(true);

    await wrapper.get('[data-testid="phone-widget-hide"]').trigger('click');
    await settle();
    expect(phoneOnScreen(wrapper)).toBe(false);
    expect(isRinging()).toBe(false);

    // The next call for this operator (here announced by the server) shows
    // the phone and rings again.
    const { useCallsStore } = await import('dashboard/stores/calls');
    useCallsStore().addCall({
      callSid: 'sipuni:incoming-2',
      status: 'ringing',
      conversationId: 502,
      inboxId: 5248,
      provider: 'sipuni',
      callDirection: 'inbound',
      browserJoinSupported: true,
    });
    await settle();
    expect(phoneOnScreen(wrapper)).toBe(true);
    expect(isRinging()).toBe(true);
  });
});
