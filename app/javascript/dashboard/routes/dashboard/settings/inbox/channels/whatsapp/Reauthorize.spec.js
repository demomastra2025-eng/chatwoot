import { flushPromises, shallowMount } from '@vue/test-utils';

import Reauthorize from './Reauthorize.vue';
import NextButton from 'next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
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
  whatsappRegistrationIncomplete = false,
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
      whatsappRegistrationIncomplete,
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

  it('submits the PIN through registration without opening Meta login', async () => {
    dispatchMock.mockResolvedValue({ id: 42 });
    const wrapper = buildWrapper({
      whatsappRegistrationIncomplete: true,
      providerConfig: {
        embedded_signup_flow: 'standard',
        phone_registration: { status: 'pin_incorrect' },
      },
    });
    await flushPromises();

    expect(setupFacebookSdkMock).not.toHaveBeenCalled();
    await wrapper.findComponent(Input).setValue('123456');
    await wrapper.vm.$nextTick();
    await wrapper.findAllComponents(NextButton)[0].trigger('click');
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith(
      'inboxes/registerWhatsAppPhoneNumber',
      { inboxId: 42, verificationPin: '123456' }
    );
    expect(initWhatsAppEmbeddedSignupMock).not.toHaveBeenCalled();
  });

  it('disables PIN retry while the previous provider outcome is unknown', async () => {
    const wrapper = buildWrapper({
      whatsappRegistrationIncomplete: true,
      providerConfig: {
        embedded_signup_flow: 'standard',
        phone_registration: { status: 'outcome_unknown' },
      },
    });
    await flushPromises();

    expect(wrapper.findComponent(Input).props('disabled')).toBe(true);
    expect(
      wrapper.findAllComponents(NextButton)[0].attributes('disabled')
    ).toBeDefined();
    expect(dispatchMock).not.toHaveBeenCalled();
  });

  it('uses the reconciled health registration status over the stale inbox status', async () => {
    const wrapper = buildWrapper({
      whatsappRegistrationIncomplete: true,
      providerConfig: {
        embedded_signup_flow: 'standard',
        phone_registration: { status: 'outcome_unknown' },
      },
    });
    await wrapper.setProps({
      phoneRegistrationStatus: 'registration_incomplete',
    });
    await wrapper.findComponent(Input).setValue('123456');

    expect(wrapper.findComponent(Input).props('disabled')).toBe(false);
  });

  it('disables PIN retry immediately after the API returns an unknown outcome', async () => {
    dispatchMock.mockRejectedValue({
      response: { data: { error_code: 'outcome_unknown' } },
    });
    const wrapper = buildWrapper({
      whatsappRegistrationIncomplete: true,
      providerConfig: {
        embedded_signup_flow: 'standard',
        phone_registration: { status: 'registration_incomplete' },
      },
    });
    await wrapper.findComponent(Input).setValue('123456');
    await wrapper.vm.$nextTick();

    await wrapper.findAllComponents(NextButton)[0].trigger('click');
    await flushPromises();

    expect(wrapper.findComponent(Input).props('disabled')).toBe(true);
    expect(dispatchMock).toHaveBeenCalledTimes(1);
  });
});
