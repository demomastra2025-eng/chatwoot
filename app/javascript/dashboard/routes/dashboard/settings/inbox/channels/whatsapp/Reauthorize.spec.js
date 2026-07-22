import { shallowMount } from '@vue/test-utils';

import Reauthorize from './Reauthorize.vue';
import InboxReconnectionRequired from '../../components/InboxReconnectionRequired.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vuex', () => ({
  useStore: () => ({ dispatch: vi.fn() }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('./utils', () => ({
  setupFacebookSdk: vi.fn().mockResolvedValue(undefined),
  initWhatsAppEmbeddedSignup: vi.fn(),
  createMessageHandler: vi.fn(),
  isValidBusinessData: vi.fn(),
  isEmbeddedSignupErrorEvent: vi.fn(),
  isEmbeddedSignupFinishEvent: vi.fn(),
  getWhatsAppEmbeddedSignupConfigErrors: vi.fn().mockReturnValue([]),
}));

const buildWrapper = (tokenStatus, reauthorizationRequired = false) =>
  shallowMount(Reauthorize, {
    props: {
      inbox: {
        id: 1,
        reauthorization_required: reauthorizationRequired,
        provider_config: {
          token_health: { status: tokenStatus },
        },
      },
    },
  });

describe('WhatsApp Reauthorize', () => {
  beforeEach(() => {
    window.chatwootConfig = {
      whatsappAppId: 'app-id',
      whatsappConfigurationId: 'configuration-id',
      whatsappApiVersion: 'v22.0',
    };
  });

  it('shows a proactive expiry explanation for an expiring token', () => {
    const wrapper = buildWrapper('expiring');

    expect(
      wrapper.findComponent(InboxReconnectionRequired).props('description')
    ).toBe('INBOX.REAUTHORIZE.EXPIRING_DESCRIPTION');
  });

  it('prioritizes the standard reconnection explanation after token failure', () => {
    const wrapper = buildWrapper('expiring', true);

    expect(
      wrapper.findComponent(InboxReconnectionRequired).props('description')
    ).toBe('INBOX.REAUTHORIZE.PRESERVE_DATA_DESCRIPTION');
  });
});
