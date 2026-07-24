import { flushPromises, shallowMount } from '@vue/test-utils';

import Reauthorize from './Reauthorize.vue';
import NextButton from 'next/button/Button.vue';
import InboxReconnectionRequired from '../../components/InboxReconnectionRequired.vue';

const setupFacebookSdkMock = vi.hoisted(() => vi.fn());
const initWhatsAppEmbeddedSignupMock = vi.hoisted(() => vi.fn());
const dispatchMock = vi.hoisted(() => vi.fn());

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vuex', () => ({
  useStore: () => ({ dispatch: dispatchMock }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/store/utils/api', () => ({
  parseAPIErrorResponse: vi.fn(),
}));

vi.mock('dashboard/api/channel/whatsappChannel', () => ({
  default: { logEmbeddedSignupSession: vi.fn() },
}));

vi.mock('./utils', () => ({
  setupFacebookSdk: setupFacebookSdkMock,
  initWhatsAppEmbeddedSignup: initWhatsAppEmbeddedSignupMock,
  createMessageHandler: callback => callback,
  isValidBusinessData: vi.fn(() => false),
  embeddedSignupFlowForEvent: vi.fn(() => 'standard'),
  EMBEDDED_SIGNUP_FLOW: {
    STANDARD: 'standard',
    COEXISTENCE: 'coexistence',
  },
  isEmbeddedSignupErrorEvent: vi.fn(() => false),
  isEmbeddedSignupFinishEvent: vi.fn(() => false),
  embeddedSignupSessionData: vi.fn(() => ({})),
  getWhatsAppEmbeddedSignupConfigErrors: vi.fn(() => []),
}));

const buildWrapper = ({
  tokenStatus,
  reauthorizationRequired = false,
  requiresReauthorization = false,
  providerConfig = { embedded_signup_flow: 'coexistence' },
} = {}) =>
  shallowMount(Reauthorize, {
    props: {
      inbox: {
        id: 42,
        reauthorization_required: reauthorizationRequired,
        requires_reauthorization: requiresReauthorization,
        provider_config: {
          ...providerConfig,
          ...(tokenStatus ? { token_health: { status: tokenStatus } } : {}),
        },
      },
    },
    global: {
      mocks: { $t: key => key },
      stubs: { InboxReconnectionRequired: true, NextButton: true },
    },
  });

describe('WhatsApp reauthorization', () => {
  beforeEach(() => {
    window.chatwootConfig = {
      whatsappAppId: 'app-id',
      whatsappConfigurationId: 'configuration-id',
      whatsappApiVersion: 'v22.0',
    };
    setupFacebookSdkMock.mockReset().mockResolvedValue();
    initWhatsAppEmbeddedSignupMock.mockReset();
    dispatchMock.mockReset();
  });

  it('shows a proactive expiry explanation for an expiring token', () => {
    const wrapper = buildWrapper({ tokenStatus: 'expiring' });

    expect(
      wrapper.findComponent(InboxReconnectionRequired).props('description')
    ).toBe('INBOX.REAUTHORIZE.EXPIRING_DESCRIPTION');
  });

  it('prioritizes the standard explanation after token failure', () => {
    const wrapper = buildWrapper({
      tokenStatus: 'expiring',
      reauthorizationRequired: true,
    });

    expect(
      wrapper.findComponent(InboxReconnectionRequired).props('description')
    ).toBe('INBOX.REAUTHORIZE.PRESERVE_DATA_DESCRIPTION');
  });

  it('prioritizes the standard explanation for the legacy alias', () => {
    const wrapper = buildWrapper({
      tokenStatus: 'expiring',
      requiresReauthorization: true,
    });

    expect(
      wrapper.findComponent(InboxReconnectionRequired).props('description')
    ).toBe('INBOX.REAUTHORIZE.PRESERVE_DATA_DESCRIPTION');
  });

  it('starts only one Meta login when authorization is requested repeatedly', async () => {
    let resolveLogin;
    initWhatsAppEmbeddedSignupMock.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveLogin = resolve;
        })
    );
    const wrapper = buildWrapper();
    await flushPromises();

    const firstRequest = wrapper.vm.requestAuthorization();
    const secondRequest = wrapper.vm.requestAuthorization();

    expect(initWhatsAppEmbeddedSignupMock).toHaveBeenCalledTimes(1);

    resolveLogin('authorization-code');
    await Promise.all([firstRequest, secondRequest]);
    wrapper.unmount();
  });

  it('requires an explicit flow choice for a legacy channel without persisted mode', async () => {
    initWhatsAppEmbeddedSignupMock.mockResolvedValue('authorization-code');
    const wrapper = buildWrapper({ providerConfig: {} });
    await flushPromises();

    expect(wrapper.findComponent(InboxReconnectionRequired).exists()).toBe(
      false
    );
    expect(wrapper.findAllComponents(NextButton)).toHaveLength(2);

    await wrapper.vm.requestAuthorization('coexistence');

    expect(initWhatsAppEmbeddedSignupMock).toHaveBeenCalledWith(
      'configuration-id',
      'coexistence'
    );
    wrapper.unmount();
  });

  it('reuses the server-persisted standard flow without asking the user', async () => {
    initWhatsAppEmbeddedSignupMock.mockResolvedValue('authorization-code');
    const wrapper = buildWrapper({
      providerConfig: { embedded_signup_flow: 'standard' },
    });
    await flushPromises();

    expect(wrapper.findComponent(InboxReconnectionRequired).exists()).toBe(
      true
    );
    await wrapper.vm.requestAuthorization();

    expect(initWhatsAppEmbeddedSignupMock).toHaveBeenCalledWith(
      'configuration-id',
      'standard'
    );
    wrapper.unmount();
  });
});
