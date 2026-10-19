import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { nextTick, ref } from 'vue';
import WhatsappUsageBanner from './WhatsappUsageBanner.vue';

const mocks = vi.hoisted(() => ({
  accountId: null,
  isAdmin: null,
  getMonthlyUsage: null,
  routerPush: null,
  storage: new Map(),
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({
    push: (...args) => mocks.routerPush(...args),
  }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ accountId: mocks.accountId }),
}));

vi.mock('dashboard/composables/useAdmin', () => ({
  useAdmin: () => ({ isAdmin: mocks.isAdmin }),
}));

vi.mock('dashboard/api/whatsappUsage', () => ({
  default: {
    getMonthlyUsage: (...args) => mocks.getMonthlyUsage(...args),
  },
}));

vi.mock('shared/helpers/localStorage', () => ({
  LocalStorage: {
    get: key => mocks.storage.get(key) ?? null,
    set: (key, value) => mocks.storage.set(key, value),
  },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: ref('en'),
    t: (key, values = {}) =>
      Object.entries(values).reduce(
        (message, [name, value]) => message.replace(`{${name}}`, value),
        {
          'WHATSAPP_USAGE.BANNER_TITLE':
            'WhatsApp · delivered: {deliveredCount} · total (incl. 12% VAT): ≈ {amount}',
          'WHATSAPP_USAGE.BANNER_CLICK_HINT':
            'Base Meta rate: {baseAmount} · Including 12% KZ VAT: {vatAmount}. Click to open the full WhatsApp & manager report.',
          'WHATSAPP_USAGE.BANNER_CONSECUTIVE_BADGE':
            'Consecutive: {count} (≈ {amount})',
          'WHATSAPP_USAGE.OPEN_REPORT': 'Report',
          'WHATSAPP_USAGE.FREE_QUOTA_SINGLE_SUMMARY':
            'Free service quota: {count}/{limit}',
          'WHATSAPP_USAGE.FREE_QUOTA_MULTI_SUMMARY':
            'Free service quota: {count} ({limit}/number)',
          'WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE': 'unavailable',
          'WHATSAPP_USAGE.COUNT_UNAVAILABLE': '—',
          'WHATSAPP_USAGE.DISMISS': 'Dismiss WhatsApp usage banner for today',
        }[key] || key
      ),
  }),
}));

const monthlyUsage = overrides => ({
  month: '2026-10',
  currency: 'KZT',
  estimated: true,
  official_cloud_phone_count: 1,
  eligible: true,
  delivered_count: 12,
  free_service_quota_count: 5,
  free_service_quota_limit: 1000,
  free_service_quota_limit_per_phone: 1000,
  phones: [
    {
      phone_number: '+77010000001',
      connected: true,
      free_service_quota_count: 5,
      free_service_quota_limit: 1000,
    },
  ],
  chargeable_message_count: 8,
  estimated_amount_kzt: '220',
  estimated_amount_with_vat_kzt: '246.4',
  consecutive_summary: {
    window_seconds: 300,
    consecutive_service_count: 3,
    chargeable_consecutive_count: 2,
    consecutive_ratio_percent: 25.0,
    estimated_overpayment_kzt: '18.0',
    estimated_overpayment_with_vat_kzt: '20.16',
  },
  exchange_rate: {
    month: '2026-10',
    available: true,
    rate_per_usd: '500',
  },
  ...overrides,
});

describe('WhatsappUsageBanner', () => {
  beforeEach(() => {
    mocks.accountId = ref(4);
    mocks.isAdmin = ref(true);
    mocks.routerPush = vi.fn();
    mocks.storage.clear();
    mocks.getMonthlyUsage = vi.fn().mockResolvedValue({
      data: { whatsapp_usage: monthlyUsage() },
    });
  });

  it('renders compact summary with VAT-inclusive amount and consecutive badge', async () => {
    const wrapper = mount(WhatsappUsageBanner);
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledWith(4);
    expect(wrapper.get('[data-testid="whatsapp-usage-title"]').text()).toContain(
      'WhatsApp · delivered: 12'
    );
    expect(wrapper.get('[data-testid="whatsapp-usage-title"]').text()).toContain(
      '246.4'
    );
    expect(
      wrapper.get('[data-testid="whatsapp-usage-consecutive-badge"]').text()
    ).toContain('Consecutive: 2');
  });

  it('navigates to whatsapp_reports when clicking the banner', async () => {
    const wrapper = mount(WhatsappUsageBanner);
    await flushPromises();

    await wrapper
      .get('[data-testid="whatsapp-usage-report-link"]')
      .trigger('click');

    expect(mocks.routerPush).toHaveBeenCalledWith({
      name: 'whatsapp_reports',
      params: { accountId: 4 },
    });
  });

  it('does not fetch or render for non-administrators', async () => {
    mocks.isAdmin.value = false;

    const wrapper = mount(WhatsappUsageBanner);
    await flushPromises();

    expect(mocks.getMonthlyUsage).not.toHaveBeenCalled();
    expect(wrapper.find('[role="status"]').exists()).toBe(false);
  });

  it('dismisses the banner for the current UTC day', async () => {
    const wrapper = mount(WhatsappUsageBanner);
    await flushPromises();

    await wrapper
      .get('button[aria-label="Dismiss WhatsApp usage banner for today"]')
      .trigger('click');
    await nextTick();

    expect(wrapper.find('[role="status"]').exists()).toBe(false);
  });
});
