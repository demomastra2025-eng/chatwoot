import { flushPromises, shallowMount } from '@vue/test-utils';

import WhatsappEmbeddedSignup from './WhatsappEmbeddedSignup.vue';
import NextButton from 'next/button/Button.vue';
import LoadingState from 'dashboard/components/widgets/LoadingState.vue';

const setupFacebookSdkMock = vi.hoisted(() => vi.fn());
const initWhatsAppEmbeddedSignupMock = vi.hoisted(() => vi.fn());

vi.mock('vue-i18n', () => ({
  I18nT: { template: '<span><slot /></span>' },
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vuex', () => ({
  useStore: () => ({ dispatch: vi.fn() }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({}),
  useRouter: () => ({ replace: vi.fn() }),
}));

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/store/utils/api', () => ({
  parseAPIErrorResponse: vi.fn(),
}));
vi.mock('dashboard/constants/globals.js', () => ({
  default: { WHATSAPP_EMBEDDED_SIGNUP_DOCS_URL: 'https://example.com' },
}));
vi.mock('dashboard/api/channel/whatsappChannel', () => ({
  default: { logEmbeddedSignupSession: vi.fn() },
}));
vi.mock('../helpers/inboxFlowRoutes', () => ({
  getInboxFlowRouteName: vi.fn(),
}));
vi.mock('./whatsapp/utils', () => ({
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

const buildWrapper = () =>
  shallowMount(WhatsappEmbeddedSignup, {
    global: {
      mocks: { $t: key => key },
      stubs: { Icon: true, I18nT: true, LoadingState: true, NextButton: true },
    },
  });

describe('WhatsApp Embedded Signup', () => {
  beforeEach(() => {
    window.chatwootConfig = {
      whatsappAppId: 'app-id',
      whatsappConfigurationId: 'configuration-id',
      whatsappApiVersion: 'v25.0',
    };
    setupFacebookSdkMock.mockReset();
    initWhatsAppEmbeddedSignupMock
      .mockReset()
      .mockResolvedValue('authorization-code');
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
});
