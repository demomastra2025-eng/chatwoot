import { flushPromises, shallowMount } from '@vue/test-utils';

import WhatsappEmbeddedSignup from './WhatsappEmbeddedSignup.vue';
import NextButton from 'next/button/Button.vue';
import LoadingState from 'dashboard/components/widgets/LoadingState.vue';

const setupFacebookSdkMock = vi.hoisted(() => vi.fn());
const initWhatsAppEmbeddedSignupMock = vi.hoisted(() => vi.fn());
const dispatchMock = vi.hoisted(() => vi.fn());
const routerReplaceMock = vi.hoisted(() => vi.fn());
const useAlertMock = vi.hoisted(() => vi.fn());
const whatsappChannelMock = vi.hoisted(() => ({
  logEmbeddedSignupSession: vi.fn(),
  registerEmbeddedSignupAttempt: vi.fn(),
  getEmbeddedSignupAttemptStatus: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  I18nT: { template: '<span><slot /></span>' },
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vuex', () => ({
  useStore: () => ({
    dispatch: dispatchMock,
    getters: { getCurrentUserID: 7 },
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '3' } }),
  useRouter: () => ({ replace: routerReplaceMock }),
}));

vi.mock('dashboard/composables', () => ({ useAlert: useAlertMock }));
vi.mock('dashboard/store/utils/api', () => ({
  parseAPIErrorResponse: vi.fn(),
}));
vi.mock('dashboard/constants/globals.js', () => ({
  default: { WHATSAPP_EMBEDDED_SIGNUP_DOCS_URL: 'https://example.com' },
}));
vi.mock('dashboard/api/channel/whatsappChannel', () => ({
  default: whatsappChannelMock,
}));
vi.mock('../helpers/inboxFlowRoutes', () => ({
  getInboxFlowRouteName: (_route, step) => `inbox_${step}`,
}));
vi.mock('./whatsapp/utils', async importOriginal => ({
  ...(await importOriginal()),
  setupFacebookSdk: setupFacebookSdkMock,
  initWhatsAppEmbeddedSignup: initWhatsAppEmbeddedSignupMock,
  isLikelyInAppBrowser: () => false,
}));

const PENDING_KEY = 'onelink:whatsapp-embedded-signup:3:7';
const NONCE = 'abcdefghijklmnopqrstuvwxyz012345';
const FINISH_EVENT = {
  type: 'WA_EMBEDDED_SIGNUP',
  event: 'FINISH',
  data: {
    business_id: 'business-1',
    waba_id: 'waba-1',
    phone_number_id: 'phone-1',
  },
};

const buildWrapper = () =>
  shallowMount(WhatsappEmbeddedSignup, {
    global: {
      mocks: { $t: key => key },
      stubs: { Icon: true, I18nT: true, LoadingState: true, NextButton: true },
    },
  });

const postMetaMessage = data => {
  window.dispatchEvent(
    new MessageEvent('message', {
      origin: 'https://www.facebook.com',
      data: JSON.stringify(data),
    })
  );
};

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
};

const setVisibility = state => {
  Object.defineProperty(document, 'visibilityState', {
    configurable: true,
    get: () => state,
  });
  document.dispatchEvent(new Event('visibilitychange'));
};

const mountReady = async () => {
  const wrapper = buildWrapper();
  await flushPromises();
  return wrapper;
};

const clickStandard = wrapper =>
  wrapper.findAllComponents(NextButton)[0].trigger('click');

const recoveryPanel = wrapper =>
  wrapper.find('[data-testid="whatsapp-signup-recovery"]');

const createSignupCalls = () =>
  dispatchMock.mock.calls.filter(
    ([action]) => action === 'inboxes/createWhatsAppEmbeddedSignup'
  );

describe('WhatsApp Embedded Signup', () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    window.localStorage.clear();
    window.chatwootConfig = {
      whatsappAppId: 'app-id',
      whatsappConfigurationId: 'configuration-id',
      whatsappApiVersion: 'v25.0',
    };
    setupFacebookSdkMock.mockReset().mockResolvedValue();
    initWhatsAppEmbeddedSignupMock
      .mockReset()
      .mockResolvedValue('authorization-code');
    dispatchMock.mockReset().mockResolvedValue({ id: 99 });
    routerReplaceMock.mockReset();
    useAlertMock.mockReset();
    whatsappChannelMock.logEmbeddedSignupSession
      .mockReset()
      .mockResolvedValue({});
    whatsappChannelMock.registerEmbeddedSignupAttempt
      .mockReset()
      .mockResolvedValue({ data: { status: 'pending' } });
    whatsappChannelMock.getEmbeddedSignupAttemptStatus
      .mockReset()
      .mockResolvedValue({ data: { status: 'unknown' } });
  });

  afterEach(() => {
    vi.useRealTimers();
    setVisibility('visible');
  });

  it('preloads the SDK before exposing signup and starts Meta login directly from the click', async () => {
    let resolveSdk;
    setupFacebookSdkMock.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveSdk = resolve;
        })
    );

    const wrapper = buildWrapper();

    expect(setupFacebookSdkMock).toHaveBeenCalledWith('app-id', 'v25.0');
    expect(wrapper.findComponent(LoadingState).exists()).toBe(true);
    expect(wrapper.findAllComponents(NextButton)).toHaveLength(0);

    resolveSdk();
    await flushPromises();

    const buttons = wrapper.findAllComponents(NextButton);
    expect(buttons).toHaveLength(2);

    const click = buttons[0].trigger('click');
    expect(initWhatsAppEmbeddedSignupMock).toHaveBeenCalledWith(
      'configuration-id',
      'standard'
    );
    expect(setupFacebookSdkMock).toHaveBeenCalledTimes(1);

    await click;
    wrapper.unmount();
  });

  it('opens Meta before registering the attempt so the popup keeps the tap gesture', async () => {
    const login = deferred();
    initWhatsAppEmbeddedSignupMock.mockReturnValue(login.promise);
    const wrapper = await mountReady();

    clickStandard(wrapper);

    const loginOrder =
      initWhatsAppEmbeddedSignupMock.mock.invocationCallOrder[0];
    const registerOrder =
      whatsappChannelMock.registerEmbeddedSignupAttempt.mock
        .invocationCallOrder[0];
    expect(loginOrder).toBeLessThan(registerOrder);
    const [{ signupNonce, signupType }] =
      whatsappChannelMock.registerEmbeddedSignupAttempt.mock.calls[0];
    expect(signupType).toBe('standard');
    expect(signupNonce).toMatch(/^[A-Za-z0-9_-]{32}$/);
    expect(JSON.parse(window.localStorage.getItem(PENDING_KEY))).toEqual(
      expect.objectContaining({
        nonce: signupNonce,
        flow: 'standard',
        codeSubmitted: false,
      })
    );
    wrapper.unmount();
  });

  it('keeps the desktop flow: message plus callback submit the business data at once', async () => {
    const login = deferred();
    initWhatsAppEmbeddedSignupMock.mockReturnValue(login.promise);
    const wrapper = await mountReady();

    clickStandard(wrapper);
    postMetaMessage(FINISH_EVENT);
    login.resolve('authorization-code');
    await flushPromises();

    const { signupNonce: nonce } =
      whatsappChannelMock.registerEmbeddedSignupAttempt.mock.calls[0][0];
    expect(createSignupCalls()).toEqual([
      [
        'inboxes/createWhatsAppEmbeddedSignup',
        {
          code: 'authorization-code',
          signup_type: 'standard',
          business_id: 'business-1',
          waba_id: 'waba-1',
          phone_number_id: 'phone-1',
          signup_nonce: nonce,
        },
      ],
    ]);
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'inbox_agents',
      params: { page: 'new', inbox_id: 99 },
    });
    expect(window.localStorage.getItem(PENDING_KEY)).toBeNull();
    wrapper.unmount();
  });

  it('completes with the auth code alone when Meta never posts the session message', async () => {
    const wrapper = await mountReady();

    await clickStandard(wrapper);
    await flushPromises();
    expect(createSignupCalls()).toHaveLength(0);

    vi.advanceTimersByTime(4000);
    await flushPromises();

    const [[, params]] = createSignupCalls();
    expect(params).toEqual({
      code: 'authorization-code',
      signup_type: 'standard',
      signup_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{32}$/),
    });
    expect(params).not.toHaveProperty('waba_id');
    expect(routerReplaceMock).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'inbox_agents' })
    );
    wrapper.unmount();
  });

  it('uses the message when it arrives within the grace period after the callback', async () => {
    const wrapper = await mountReady();

    await clickStandard(wrapper);
    await flushPromises();
    vi.advanceTimersByTime(1500);
    postMetaMessage(FINISH_EVENT);
    await flushPromises();
    vi.advanceTimersByTime(5000);
    await flushPromises();

    expect(createSignupCalls()).toHaveLength(1);
    expect(createSignupCalls()[0][1]).toEqual(
      expect.objectContaining({ waba_id: 'waba-1', phone_number_id: 'phone-1' })
    );
    wrapper.unmount();
  });

  it('offers to continue when only the Meta message arrives and the callback is lost', async () => {
    const lostLogin = deferred();
    initWhatsAppEmbeddedSignupMock
      .mockReturnValueOnce(lostLogin.promise)
      .mockReturnValueOnce(deferred().promise);
    const wrapper = await mountReady();

    clickStandard(wrapper);
    postMetaMessage(FINISH_EVENT);
    await flushPromises();
    expect(recoveryPanel(wrapper).exists()).toBe(false);

    vi.advanceTimersByTime(15000);
    await flushPromises();

    expect(recoveryPanel(wrapper).exists()).toBe(true);
    expect(recoveryPanel(wrapper).text()).toContain('RECOVERY.WAITING_TITLE');
    expect(createSignupCalls()).toHaveLength(0);

    wrapper.find('[data-testid="whatsapp-signup-continue"]').trigger('click');
    expect(initWhatsAppEmbeddedSignupMock).toHaveBeenCalledTimes(2);
    expect(initWhatsAppEmbeddedSignupMock).toHaveBeenLastCalledWith(
      'configuration-id',
      'standard'
    );
    wrapper.unmount();
  });

  it('shows the continue state after the tab returns from Meta with nothing delivered, and still accepts a late code', async () => {
    const login = deferred();
    initWhatsAppEmbeddedSignupMock.mockReturnValue(login.promise);
    const wrapper = await mountReady();

    clickStandard(wrapper);
    setVisibility('hidden');
    setVisibility('visible');
    await flushPromises();
    expect(recoveryPanel(wrapper).exists()).toBe(false);

    vi.advanceTimersByTime(5000);
    await flushPromises();
    expect(recoveryPanel(wrapper).exists()).toBe(true);

    login.resolve('late-code');
    await flushPromises();
    expect(recoveryPanel(wrapper).exists()).toBe(false);
    vi.advanceTimersByTime(4000);
    await flushPromises();

    expect(createSignupCalls()[0][1]).toEqual(
      expect.objectContaining({ code: 'late-code', signup_type: 'standard' })
    );
    wrapper.unmount();
  });

  it('replaces the endless spinner with a retry state on timeout', async () => {
    initWhatsAppEmbeddedSignupMock.mockReturnValue(deferred().promise);
    const wrapper = await mountReady();

    clickStandard(wrapper);
    await flushPromises();
    expect(wrapper.findComponent(LoadingState).exists()).toBe(true);

    vi.advanceTimersByTime(10 * 60 * 1000);
    await flushPromises();

    expect(wrapper.findComponent(LoadingState).exists()).toBe(false);
    expect(recoveryPanel(wrapper).text()).toContain('RECOVERY.TIMEOUT_TITLE');
    expect(window.localStorage.getItem(PENDING_KEY)).toBeNull();
    wrapper.unmount();
  });

  it('resumes after a reload and opens the inbox the server already created', async () => {
    window.localStorage.setItem(
      PENDING_KEY,
      JSON.stringify({
        nonce: NONCE,
        flow: 'standard',
        startedAt: Date.now(),
        codeSubmitted: true,
      })
    );
    whatsappChannelMock.getEmbeddedSignupAttemptStatus.mockResolvedValue({
      data: { status: 'completed', inbox_id: 42 },
    });

    const wrapper = await mountReady();

    expect(
      whatsappChannelMock.getEmbeddedSignupAttemptStatus
    ).toHaveBeenCalledWith({ signupNonce: NONCE });
    expect(dispatchMock).toHaveBeenCalledWith('inboxes/get');
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'inbox_agents',
      params: { page: 'new', inbox_id: 42 },
    });
    expect(window.localStorage.getItem(PENDING_KEY)).toBeNull();
    wrapper.unmount();
  });

  it('keeps polling while the server is still processing the resumed attempt', async () => {
    window.localStorage.setItem(
      PENDING_KEY,
      JSON.stringify({
        nonce: NONCE,
        flow: 'standard',
        startedAt: Date.now(),
        codeSubmitted: true,
      })
    );
    whatsappChannelMock.getEmbeddedSignupAttemptStatus
      .mockResolvedValueOnce({ data: { status: 'processing' } })
      .mockResolvedValueOnce({ data: { status: 'completed', inbox_id: 5 } });

    const wrapper = await mountReady();
    expect(wrapper.findComponent(LoadingState).props('message')).toBe(
      'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RESUMING'
    );

    vi.advanceTimersByTime(3000);
    await flushPromises();

    expect(
      whatsappChannelMock.getEmbeddedSignupAttemptStatus
    ).toHaveBeenCalledTimes(2);
    expect(routerReplaceMock).toHaveBeenCalledWith(
      expect.objectContaining({ params: { page: 'new', inbox_id: 5 } })
    );
    wrapper.unmount();
  });

  it('offers to continue the same flow after a reload lost the Meta result', async () => {
    window.localStorage.setItem(
      PENDING_KEY,
      JSON.stringify({
        nonce: NONCE,
        flow: 'coexistence',
        startedAt: Date.now(),
        codeSubmitted: false,
      })
    );
    whatsappChannelMock.getEmbeddedSignupAttemptStatus.mockResolvedValue({
      data: { status: 'pending', signup_type: 'coexistence' },
    });
    initWhatsAppEmbeddedSignupMock.mockReturnValue(deferred().promise);

    const wrapper = await mountReady();

    expect(recoveryPanel(wrapper).text()).toContain(
      'RECOVERY.INTERRUPTED_TITLE'
    );
    expect(window.localStorage.getItem(PENDING_KEY)).toBeNull();

    wrapper.find('[data-testid="whatsapp-signup-continue"]').trigger('click');
    expect(initWhatsAppEmbeddedSignupMock).toHaveBeenCalledWith(
      'configuration-id',
      'coexistence'
    );
    wrapper.unmount();
  });

  it('ignores an expired pending attempt', async () => {
    window.localStorage.setItem(
      PENDING_KEY,
      JSON.stringify({
        nonce: NONCE,
        flow: 'standard',
        startedAt: Date.now() - 31 * 60 * 1000,
        codeSubmitted: true,
      })
    );

    const wrapper = await mountReady();

    expect(
      whatsappChannelMock.getEmbeddedSignupAttemptStatus
    ).not.toHaveBeenCalled();
    expect(recoveryPanel(wrapper).exists()).toBe(false);
    expect(wrapper.findAllComponents(NextButton)).toHaveLength(2);
    wrapper.unmount();
  });

  it('asks the server for the outcome when the completion response was lost', async () => {
    dispatchMock.mockImplementation(action =>
      action === 'inboxes/createWhatsAppEmbeddedSignup'
        ? Promise.reject(new Error('Network Error'))
        : Promise.resolve()
    );
    whatsappChannelMock.getEmbeddedSignupAttemptStatus.mockResolvedValue({
      data: { status: 'completed', inbox_id: 77 },
    });
    const wrapper = await mountReady();

    await clickStandard(wrapper);
    postMetaMessage(FINISH_EVENT);
    await flushPromises();

    expect(
      whatsappChannelMock.getEmbeddedSignupAttemptStatus
    ).toHaveBeenCalledTimes(1);
    expect(routerReplaceMock).toHaveBeenCalledWith(
      expect.objectContaining({ params: { page: 'new', inbox_id: 77 } })
    );
    expect(useAlertMock).not.toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.WHATSAPP.API.ERROR_MESSAGE'
    );
    wrapper.unmount();
  });

  it('shows a retry state with the reason when code-only completion fails', async () => {
    const apiError = Object.assign(new Error('Request failed'), {
      response: { status: 422, data: { error_code: 'waba_ambiguous' } },
    });
    dispatchMock.mockImplementation(action =>
      action === 'inboxes/createWhatsAppEmbeddedSignup'
        ? Promise.reject(apiError)
        : Promise.resolve()
    );
    const wrapper = await mountReady();

    await clickStandard(wrapper);
    await flushPromises();
    vi.advanceTimersByTime(4000);
    await flushPromises();

    expect(recoveryPanel(wrapper).text()).toContain('RECOVERY.WABA_AMBIGUOUS');
    expect(window.localStorage.getItem(PENDING_KEY)).toBeNull();
    wrapper.unmount();
  });

  it('cancelling the retry state returns to the start buttons', async () => {
    initWhatsAppEmbeddedSignupMock.mockReturnValue(deferred().promise);
    const wrapper = await mountReady();

    clickStandard(wrapper);
    vi.advanceTimersByTime(10 * 60 * 1000);
    await flushPromises();
    await wrapper
      .find('[data-testid="whatsapp-signup-cancel"]')
      .trigger('click');

    expect(recoveryPanel(wrapper).exists()).toBe(false);
    expect(wrapper.findAllComponents(NextButton)).toHaveLength(2);
    wrapper.unmount();
  });
});
