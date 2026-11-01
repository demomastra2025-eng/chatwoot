import { mount, flushPromises } from '@vue/test-utils';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import TelegramSoftphoneCard from './TelegramSoftphoneCard.vue';

const mockGetStatus = vi.fn();
const mockIssueLinkToken = vi.fn();
const mockSetOnLine = vi.fn();
const mockDisconnect = vi.fn();
const mockBootstrapIncomingSupport = vi.fn(() => Promise.resolve());
const mockUseAlert = vi.fn();

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key}:${JSON.stringify(params)}` : key),
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mockUseAlert(...args),
}));

vi.mock('dashboard/api/telephony/telegramSoftphone', () => ({
  default: {
    getStatus: (...args) => mockGetStatus(...args),
    issueLinkToken: (...args) => mockIssueLinkToken(...args),
    setOnLine: (...args) => mockSetOnLine(...args),
    disconnect: (...args) => mockDisconnect(...args),
  },
}));

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: {
    bootstrapIncomingSupport: (...args) =>
      mockBootstrapIncomingSupport(...args),
  },
}));

const ButtonStub = {
  name: 'Button',
  props: ['label', 'disabled'],
  emits: ['click'],
  template:
    '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};

const mountCard = () =>
  mount(TelegramSoftphoneCard, {
    global: {
      stubs: {
        Button: ButtonStub,
      },
    },
  });

describe('TelegramSoftphoneCard.vue', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('issues a single-use deep link and opens Telegram when unlinked', async () => {
    mockGetStatus.mockResolvedValue({
      configured: true,
      connected: false,
      on_line: false,
      bot_username: 'onelink_calls_bot',
    });
    mockIssueLinkToken.mockResolvedValue({
      configured: true,
      connected: false,
      deep_link: 'https://t.me/onelink_calls_bot?start=tok123',
    });
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null);

    const wrapper = mountCard();
    await flushPromises();

    expect(wrapper.text()).toContain('@onelink_calls_bot');

    await wrapper
      .find('[data-testid="telegram-softphone-connect"]')
      .trigger('click');
    await flushPromises();

    expect(mockIssueLinkToken).toHaveBeenCalledTimes(1);
    expect(openSpy).toHaveBeenCalledWith(
      'https://t.me/onelink_calls_bot?start=tok123',
      '_blank',
      'noopener,noreferrer'
    );
    expect(
      wrapper.find('[data-testid="telegram-softphone-deeplink-box"]').exists()
    ).toBe(true);
    openSpy.mockRestore();
  });

  it('toggles operator on-line and off-line and restores browser SIP lease on exit', async () => {
    mockGetStatus.mockResolvedValue({
      configured: true,
      connected: true,
      on_line: false,
      username: 'aset_operator',
      sip_lines: [{ line_key: 'l1', registered: true }],
    });
    mockSetOnLine
      .mockResolvedValueOnce({
        configured: true,
        connected: true,
        on_line: true,
        username: 'aset_operator',
        sip_lines: [{ line_key: 'l1', registered: true }],
      })
      .mockResolvedValueOnce({
        configured: true,
        connected: true,
        on_line: false,
        username: 'aset_operator',
        sip_lines: [],
      });

    const wrapper = mountCard();
    await flushPromises();

    expect(wrapper.text()).toContain('@aset_operator');
    expect(
      wrapper.find('[data-testid="telegram-softphone-badge"]').text()
    ).toContain('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.STATUS_OFFLINE');

    await wrapper
      .find('[data-testid="telegram-softphone-toggle"]')
      .trigger('click');
    await flushPromises();

    expect(mockSetOnLine).toHaveBeenNthCalledWith(1, true);
    expect(
      wrapper.find('[data-testid="telegram-softphone-badge"]').text()
    ).toContain('PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.STATUS_ONLINE');
    expect(mockBootstrapIncomingSupport).not.toHaveBeenCalled();

    await wrapper
      .find('[data-testid="telegram-softphone-toggle"]')
      .trigger('click');
    await flushPromises();

    expect(mockSetOnLine).toHaveBeenNthCalledWith(2, false);
    expect(mockBootstrapIncomingSupport).toHaveBeenCalledTimes(1);
  });

  it('disconnects linked Telegram account and re-bootstraps browser webphone', async () => {
    mockGetStatus.mockResolvedValue({
      configured: true,
      connected: true,
      on_line: true,
      username: 'aset_operator',
      sip_lines: [],
    });
    mockDisconnect.mockResolvedValue({
      configured: true,
      connected: false,
      on_line: false,
      username: null,
      sip_lines: [],
    });

    const wrapper = mountCard();
    await flushPromises();

    await wrapper
      .find('[data-testid="telegram-softphone-disconnect"]')
      .trigger('click');
    await flushPromises();

    expect(mockDisconnect).toHaveBeenCalledTimes(1);
    expect(mockBootstrapIncomingSupport).toHaveBeenCalledTimes(1);
    expect(
      wrapper.find('[data-testid="telegram-softphone-connect"]').exists()
    ).toBe(true);
  });
});
