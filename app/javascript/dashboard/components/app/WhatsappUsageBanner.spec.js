import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { nextTick, ref } from 'vue';
import WhatsappUsageBanner from './WhatsappUsageBanner.vue';

const mocks = vi.hoisted(() => ({
  accountId: null,
  isAdmin: null,
  getMonthlyUsage: null,
  storage: new Map(),
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
            'OneLink · delivered: {deliveredCount} · total ≈ {amount}',
          'WHATSAPP_USAGE.BANNER_TOOLTIP':
            'Only OneLink WhatsApp Cloud messages are counted; app and Web messages are excluded. Service messages {serviceAmount}; templates {templateAmount}; delivered templates {templateCount}; rate month {rateMonth}; requested {requestedDate}; effective {effectiveDate}; {rate} KZT per USD; before volume discounts. Unpriced: {unpricedCount}; unknown: {unknownCount}. Free services {freeQuotaCount}; by number: {freeQuotaByPhone}; coverage: {freeQuotaHistoryStatus}. Per-category non-billable messages are separate from the monthly free allowance. Meta time zone period may differ; exact remaining unavailable.',
          'WHATSAPP_USAGE.BREAKDOWN_TRIGGER':
            'Message breakdown; {count} delivered',
          'WHATSAPP_USAGE.BREAKDOWN_TITLE': 'Messages sent from OneLink',
          'WHATSAPP_USAGE.CATEGORY_SERVICE': 'Ordinary service',
          'WHATSAPP_USAGE.CATEGORY_UTILITY': 'Utility notifications',
          'WHATSAPP_USAGE.CATEGORY_MARKETING': 'Marketing',
          'WHATSAPP_USAGE.CATEGORY_AUTH': 'Authentication',
          'WHATSAPP_USAGE.CATEGORY_AUTH_INTERNATIONAL':
            'International authentication',
          'WHATSAPP_USAGE.CATEGORY_REFERRAL_CONVERSION': 'Referral conversion',
          'WHATSAPP_USAGE.CATEGORY_UNKNOWN': 'Unknown category',
          'WHATSAPP_USAGE.CATEGORY_DELIVERED': 'Delivered: {count}',
          'WHATSAPP_USAGE.CATEGORY_BILLABILITY':
            'Chargeable: {chargeable} · non-billable: {free} · billability unknown: {unknown}',
          'WHATSAPP_USAGE.CATEGORY_BREAKDOWN_UNAVAILABLE':
            'Category breakdown is not available yet.',
          'WHATSAPP_USAGE.CATEGORY_BREAKDOWN_NOTE':
            'Other categories may contribute to the overall delivered count. Non-billable is separate from the monthly service allowance.',
          'WHATSAPP_USAGE.FREE_QUOTA_SINGLE_SUMMARY':
            'Free service messages (UTC): {count}/{limit}',
          'WHATSAPP_USAGE.FREE_QUOTA_MULTI_SUMMARY':
            'Free service messages (UTC): {count} · limit {limit}/number',
          'WHATSAPP_USAGE.FREE_QUOTA_BY_PHONE':
            'number {phone}: {count}/{limit}',
          'WHATSAPP_USAGE.HISTORY_INCOMPLETE': 'history incomplete',
          'WHATSAPP_USAGE.HISTORY_COMPLETE': 'UTC-month history complete',
          'WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE': 'unavailable',
          'WHATSAPP_USAGE.COUNT_UNAVAILABLE': '—',
          'WHATSAPP_USAGE.VALUE_UNAVAILABLE': 'unavailable',
          'WHATSAPP_USAGE.RATE_UNAVAILABLE': 'unavailable',
          'WHATSAPP_USAGE.ESTIMATE_INCOMPLETE': 'Estimate incomplete',
          'WHATSAPP_USAGE.DISMISS': 'Dismiss WhatsApp usage banner',
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
  free_service_quota_unknown_count: 0,
  free_service_quota_limit: 1000,
  free_service_quota_limit_per_phone: 1000,
  free_service_quota_complete: true,
  phones: [
    {
      phone_number: '+77010000001',
      connected: true,
      free_service_quota_count: 5,
      free_service_quota_limit: 1000,
    },
  ],
  service_delivered_count: 8,
  template_delivered_count: 3,
  chargeable_service_count: 6,
  chargeable_template_count: 2,
  chargeable_message_count: 8,
  unpriced_billable_count: 0,
  unknown_billable_count: 0,
  category_breakdown: [
    {
      category: 'service',
      delivered_count: 8,
      chargeable_count: 6,
      free_count: 2,
      unknown_billable_count: 0,
    },
    {
      category: 'utility',
      delivered_count: 1,
      chargeable_count: 1,
      free_count: 0,
      unknown_billable_count: 0,
    },
    {
      category: 'marketing',
      delivered_count: 2,
      chargeable_count: 1,
      free_count: 1,
      unknown_billable_count: 0,
    },
    {
      category: 'authentication',
      delivered_count: 1,
      chargeable_count: 0,
      free_count: 1,
      unknown_billable_count: 0,
    },
    {
      category: 'authentication-international',
      delivered_count: 0,
      chargeable_count: 0,
      free_count: 0,
      unknown_billable_count: 0,
    },
    {
      category: 'referral_conversion',
      delivered_count: 0,
      chargeable_count: 0,
      free_count: 0,
      unknown_billable_count: 0,
    },
    {
      category: 'unknown',
      delivered_count: 0,
      chargeable_count: 0,
      free_count: 0,
      unknown_billable_count: 0,
    },
  ],
  estimated_service_amount_kzt: 800,
  estimated_template_amount_kzt: 300,
  estimated_amount_kzt: 1100,
  estimated_amount_scope: 'billable_message_base_rates',
  template_costs_included: true,
  volume_discounts_included: false,
  exchange_rate: {
    month: '2026-10',
    requested_date: '2026-10-01',
    effective_date: '2026-10-01',
    rate_per_usd: 500.25,
    source_url: 'https://www.nationalbank.kz/',
    available: true,
  },
  coverage_complete: true,
  estimate_complete: true,
  ...overrides,
});

const response = payload => ({ data: { whatsapp_usage: payload } });

const mountBanner = () => mount(WhatsappUsageBanner);
const openBreakdown = async wrapper => {
  await wrapper
    .get('[data-testid="whatsapp-usage-breakdown-trigger"]')
    .trigger('click');
  return wrapper.get('[data-testid="whatsapp-usage-breakdown"]').text();
};

describe('WhatsappUsageBanner', () => {
  beforeEach(() => {
    mocks.accountId = ref(11);
    mocks.isAdmin = ref(true);
    mocks.getMonthlyUsage = vi.fn(async () => response(monthlyUsage()));
    mocks.storage = new Map();
    vi.useRealTimers();
  });

  it('shows the non-integer total including service messages and templates', async () => {
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(
        monthlyUsage({
          service_delivered_count: 1008,
          template_delivered_count: 3,
          chargeable_service_count: 8,
          chargeable_template_count: 2,
          chargeable_message_count: 10,
          estimated_service_amount_kzt: 64.25,
          estimated_template_amount_kzt: 10.5,
          estimated_amount_kzt: 74.75,
          unpriced_billable_count: 2,
          unknown_billable_count: 1,
          coverage_complete: false,
          estimate_complete: false,
        })
      )
    );

    const wrapper = mountBanner();
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledWith(11);
    const summary = wrapper.get('[data-testid="whatsapp-usage-title"]');
    expect(summary.text()).toContain('delivered: 12');
    expect(summary.text()).toContain('total ≈');
    expect(summary.text()).toContain('74.75');
    expect(summary.text()).toContain('Free service messages (UTC): 5/1,000');
    expect(summary.element.childElementCount).toBe(0);
    expect(
      wrapper
        .get('[data-testid="whatsapp-usage-breakdown-trigger"]')
        .attributes('aria-label')
    ).toContain('Free service messages (UTC): 5/1,000');
    expect(summary.text()).not.toContain('Estimate incomplete');
    expect(wrapper.text()).not.toContain('Estimate incomplete');
    expect(wrapper.text()).not.toContain('Template cost separate');
    const tooltip = (await openBreakdown(wrapper)).replace(/\s+/g, ' ');
    expect(tooltip).toContain('Estimate incomplete');
    expect(tooltip).toContain(
      'Service messages KZT 64.25; templates KZT 10.5; delivered templates 3'
    );
    expect(tooltip).toContain('Unpriced: 2; unknown: 1');
    expect(tooltip).toContain(
      'rate month 2026-10; requested 2026-10-01; effective 2026-10-01; 500.25 KZT per USD; before volume discounts'
    );
    expect(wrapper.find('section[role="status"]').exists()).toBe(true);
    expect(
      wrapper
        .find('button[aria-label="Dismiss WhatsApp usage banner"]')
        .exists()
    ).toBe(true);

    wrapper.unmount();
  });

  it('shows OneLink category counts on hover, focus and click, and closes with Escape', async () => {
    const categoryBreakdown = monthlyUsage({}).category_breakdown.map(row => {
      if (row.category === 'authentication') {
        return { ...row, delivered_count: 0, free_count: 0 };
      }
      if (row.category === 'unknown') {
        return { ...row, delivered_count: 1, unknown_billable_count: 1 };
      }
      return row;
    });
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(
        monthlyUsage({
          category_breakdown: categoryBreakdown,
          unknown_billable_count: 1,
          estimate_complete: false,
        })
      )
    );

    const wrapper = mountBanner();
    await flushPromises();

    const trigger = wrapper.get(
      '[data-testid="whatsapp-usage-breakdown-trigger"]'
    );
    const interactionArea = wrapper.get(
      '[data-testid="whatsapp-usage-breakdown-wrapper"]'
    );

    expect(
      wrapper.get('[data-testid="whatsapp-usage-title"]').text()
    ).toContain('OneLink');

    await interactionArea.trigger('mouseenter');
    let details = wrapper.get('[data-testid="whatsapp-usage-breakdown"]');
    expect(details.text()).toContain('Ordinary service');
    expect(details.text()).toContain('Utility notifications');
    expect(details.text()).toContain('Marketing');
    expect(details.text()).toContain('Unknown category');
    expect(details.text()).toContain('Delivered: 8');
    expect(details.text()).toContain('Delivered: 1');
    expect(details.text()).toContain(
      'Chargeable: 6 · non-billable: 2 · billability unknown: 0'
    );
    expect(details.text()).toContain(
      'Chargeable: 0 · non-billable: 0 · billability unknown: 1'
    );
    expect(details.text()).toContain('Only OneLink WhatsApp Cloud messages');

    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })
    );
    await nextTick();
    expect(
      wrapper.find('[data-testid="whatsapp-usage-breakdown"]').exists()
    ).toBe(false);
    expect(trigger.attributes('aria-expanded')).toBe('false');

    await interactionArea.trigger('mouseleave');
    expect(
      wrapper.find('[data-testid="whatsapp-usage-breakdown"]').exists()
    ).toBe(false);

    await trigger.trigger('focusin');
    expect(
      wrapper.find('[data-testid="whatsapp-usage-breakdown"]').exists()
    ).toBe(true);
    await trigger.trigger('focusout', { relatedTarget: document.body });
    expect(
      wrapper.find('[data-testid="whatsapp-usage-breakdown"]').exists()
    ).toBe(false);

    await trigger.trigger('click');
    expect(trigger.attributes('aria-expanded')).toBe('true');
    details = wrapper.get('[data-testid="whatsapp-usage-breakdown"]');
    expect(details.attributes('tabindex')).toBe('0');
    expect(details.text()).toContain(
      'Non-billable is separate from the monthly'
    );

    await details.trigger('focusin');
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })
    );
    await nextTick();
    expect(
      wrapper.find('[data-testid="whatsapp-usage-breakdown"]').exists()
    ).toBe(false);
    expect(trigger.attributes('aria-expanded')).toBe('false');

    wrapper.unmount();
  });

  it('shows one number’s observed free service count as a UTC fraction', async () => {
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(
        monthlyUsage({
          free_service_quota_count: 256,
          phones: [
            {
              phone_number: '+77010000001',
              connected: true,
              free_service_quota_count: 256,
              free_service_quota_limit: 1000,
            },
          ],
        })
      )
    );

    const wrapper = mountBanner();
    await flushPromises();

    expect(wrapper.text()).toContain('Free service messages (UTC): 256/1,000');
    expect(wrapper.text()).not.toContain('256/2,000');

    wrapper.unmount();
  });

  it('does not replace missing category data with zero and closes details on account switch', async () => {
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(
        monthlyUsage({
          category_breakdown: undefined,
          delivered_count: undefined,
        })
      )
    );

    const wrapper = mountBanner();
    await flushPromises();

    expect(
      wrapper.get('[data-testid="whatsapp-usage-title"]').text()
    ).toContain('delivered: —');
    expect(wrapper.text()).not.toContain('Estimate incomplete');
    const details = await openBreakdown(wrapper);
    expect(details).toContain('Category breakdown is not available yet.');
    expect(details).toContain('Estimate incomplete');
    expect(wrapper.text()).not.toContain('Delivered: 0');

    mocks.getMonthlyUsage = vi.fn(async () => response(monthlyUsage()));
    mocks.accountId.value = 12;
    await nextTick();
    await flushPromises();

    expect(
      wrapper.find('[data-testid="whatsapp-usage-breakdown"]').exists()
    ).toBe(false);
    expect(
      wrapper
        .get('[data-testid="whatsapp-usage-breakdown-trigger"]')
        .attributes('aria-expanded')
    ).toBe('false');

    wrapper.unmount();
  });

  it('closes pinned category details after a click outside', async () => {
    const wrapper = mountBanner();
    await flushPromises();

    await openBreakdown(wrapper);
    expect(
      wrapper.find('[data-testid="whatsapp-usage-breakdown"]').exists()
    ).toBe(true);

    document.body.dispatchEvent(new Event('pointerdown', { bubbles: true }));
    document.body.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await nextTick();

    expect(
      wrapper.find('[data-testid="whatsapp-usage-breakdown"]').exists()
    ).toBe(false);
    wrapper.unmount();
  });

  it('shows delivered messages and UTC-observed free services separately for each number', async () => {
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(
        monthlyUsage({
          delivered_count: 560,
          official_cloud_phone_count: 2,
          free_service_quota_count: 524,
          free_service_quota_unknown_count: 2,
          free_service_quota_limit: 2000,
          free_service_quota_complete: false,
          coverage_complete: true,
          estimate_complete: true,
          phones: [
            {
              phone_number: '+770100008558',
              connected: true,
              free_service_quota_count: 512,
              free_service_quota_limit: 1000,
            },
            {
              phone_number: '+770100000002',
              connected: true,
              free_service_quota_count: 12,
              free_service_quota_limit: 1000,
            },
          ],
        })
      )
    );

    const wrapper = mountBanner();
    await flushPromises();

    expect(wrapper.text()).toContain('delivered: 560');
    expect(wrapper.text()).toContain(
      'Free service messages (UTC): 524 · limit 1,000/number'
    );
    expect(
      wrapper.get('[data-testid="whatsapp-usage-title"]').text()
    ).not.toContain('Estimate incomplete');
    const tooltip = (await openBreakdown(wrapper)).replace(/\s+/g, ' ');
    expect(tooltip).toContain('Estimate incomplete');
    expect(tooltip).toContain(
      'by number: number …8558: 512/1,000; number …0002: 12/1,000'
    );
    expect(tooltip).toContain('Meta time zone period may differ');
    expect(tooltip).toContain('exact remaining unavailable');
    expect(
      wrapper.findAll('[data-testid="whatsapp-usage-title"]')
    ).toHaveLength(1);

    wrapper.unmount();
  });

  it('shows a confirmed free total without requiring an exchange rate', async () => {
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(
        monthlyUsage({
          chargeable_service_count: 0,
          chargeable_template_count: 0,
          chargeable_message_count: 0,
          estimated_service_amount_kzt: 0,
          estimated_template_amount_kzt: 0,
          estimated_amount_kzt: 0,
          exchange_rate: { available: false },
        })
      )
    );
    const wrapper = mountBanner();
    await flushPromises();

    expect(
      wrapper
        .get('[data-testid="whatsapp-usage-title"]')
        .text()
        .replace(/\s+/g, ' ')
    ).toContain('total ≈ KZT 0');
    expect(wrapper.text()).not.toContain('Estimate incomplete');
    wrapper.unmount();
  });

  it('does not request usage for non-administrators', async () => {
    mocks.isAdmin.value = false;

    const wrapper = mountBanner();
    await flushPromises();

    expect(mocks.getMonthlyUsage).not.toHaveBeenCalled();
    expect(wrapper.find('section').exists()).toBe(false);

    wrapper.unmount();
  });

  it('does not show an unconfirmed zero while paid messages lack an exchange rate', async () => {
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(
        monthlyUsage({
          estimated_service_amount_kzt: 0,
          estimated_template_amount_kzt: 0,
          estimated_amount_kzt: 0,
          exchange_rate: { available: false },
          estimate_complete: false,
        })
      )
    );
    const wrapper = mountBanner();
    await flushPromises();

    expect(
      wrapper.get('[data-testid="whatsapp-usage-title"]').text()
    ).toContain('total ≈ unavailable');
    expect(wrapper.text()).not.toContain('Estimate incomplete');
    expect((await openBreakdown(wrapper)).replace(/\s+/g, ' ')).toContain(
      'Estimate incomplete'
    );
    wrapper.unmount();
  });

  it('retries a temporary initial failure while visible and clears stale usage', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-02T00:00:00.000Z'));
    const visibilityDescriptor = Object.getOwnPropertyDescriptor(
      document,
      'visibilityState'
    );
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      value: 'visible',
    });
    mocks.getMonthlyUsage = vi
      .fn()
      .mockRejectedValueOnce(new Error('temporary'))
      .mockResolvedValueOnce(response(monthlyUsage()));

    const wrapper = mountBanner();
    await flushPromises();
    expect(wrapper.find('section').exists()).toBe(false);

    await vi.advanceTimersByTimeAsync(60_000);
    await flushPromises();
    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(2);
    expect(wrapper.find('section').exists()).toBe(true);

    wrapper.unmount();
    if (visibilityDescriptor)
      Object.defineProperty(document, 'visibilityState', visibilityDescriptor);
    else delete document.visibilityState;
    vi.useRealTimers();
  });

  it('stops automatic retries after access is denied', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-02T00:00:00.000Z'));
    mocks.getMonthlyUsage = vi
      .fn()
      .mockRejectedValue({ response: { status: 403 } });

    const wrapper = mountBanner();
    await flushPromises();
    await vi.advanceTimersByTimeAsync(120_000);
    window.dispatchEvent(new Event('focus'));
    document.dispatchEvent(new Event('visibilitychange'));
    await flushPromises();
    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(1);
    expect(wrapper.find('section').exists()).toBe(false);

    wrapper.unmount();
    vi.useRealTimers();
  });

  it('hides accounts without an eligible official Cloud WhatsApp phone', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-02T00:00:00.000Z'));
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(monthlyUsage({ eligible: false, official_cloud_phone_count: 0 }))
    );

    const wrapper = mountBanner();
    await flushPromises();

    expect(wrapper.find('section').exists()).toBe(false);
    await vi.advanceTimersByTimeAsync(120_000);
    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(1);

    wrapper.unmount();
    vi.useRealTimers();
  });

  it('keeps a complete estimate when priced template costs are included', async () => {
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(
        monthlyUsage({
          template_delivered_count: 3,
          coverage_complete: true,
          chargeable_template_count: 3,
          chargeable_message_count: 9,
          estimated_service_amount_kzt: 800,
          estimated_template_amount_kzt: 350,
          estimated_amount_kzt: 1150,
          template_costs_included: true,
          estimate_complete: true,
        })
      )
    );

    const wrapper = mountBanner();
    await flushPromises();

    expect((await openBreakdown(wrapper)).replace(/\s+/g, ' ')).toContain(
      'templates KZT 350'
    );
    expect(wrapper.text()).not.toContain('Estimate incomplete');
    expect(wrapper.find('section').exists()).toBe(true);

    wrapper.unmount();
  });

  it('shows an unavailable estimate when the monthly FX rate is missing', async () => {
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(
        monthlyUsage({
          estimated_service_amount_kzt: null,
          estimated_template_amount_kzt: null,
          estimated_amount_kzt: null,
          exchange_rate: {
            month: '2026-10',
            requested_date: '2026-10-01',
            effective_date: null,
            rate_per_usd: null,
            source_url: null,
            available: false,
          },
          estimate_complete: false,
        })
      )
    );

    const wrapper = mountBanner();
    await flushPromises();

    expect(
      wrapper.get('[data-testid="whatsapp-usage-title"]').text()
    ).toContain('total ≈ unavailable');
    expect(
      wrapper.get('[data-testid="whatsapp-usage-title"]').text()
    ).not.toContain('KZT 0');
    const details = (await openBreakdown(wrapper)).replace(/\s+/g, ' ');
    expect(details).toContain('Estimate incomplete');
    expect(details).toContain('effective unavailable; unavailable KZT per USD');

    wrapper.unmount();
  });

  it('does not display absent billing counts as known zeroes', async () => {
    const payload = monthlyUsage({
      unpriced_billable_count: undefined,
      unknown_billable_count: undefined,
      estimate_complete: true,
    });
    mocks.getMonthlyUsage = vi.fn(async () => response(payload));

    const wrapper = mountBanner();
    await flushPromises();

    const details = (await openBreakdown(wrapper)).replace(/\s+/g, ' ');
    expect(details).toContain('Unpriced: —; unknown: —');
    expect(details).toContain('Estimate incomplete');

    wrapper.unmount();
  });

  it('stores dismissal by account and UTC day and shows another account', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-03T12:00:00.000Z'));
    const wrapper = mountBanner();
    await flushPromises();

    await wrapper
      .get('button[aria-label="Dismiss WhatsApp usage banner"]')
      .trigger('click');
    expect(
      mocks.storage.get('dismissedWhatsappUsage::daily::11:2026-10-03')
    ).toBe(true);
    expect(wrapper.find('section').exists()).toBe(false);

    mocks.getMonthlyUsage = vi.fn(async accountId =>
      response(monthlyUsage({ delivered_count: accountId === 12 ? 28 : 12 }))
    );
    mocks.accountId.value = 12;
    await nextTick();
    await flushPromises();

    expect(wrapper.text()).toContain('delivered: 28');
    expect(wrapper.find('section').exists()).toBe(true);

    wrapper.unmount();
    vi.useRealTimers();
  });

  it('ignores a legacy monthly dismissal and keeps a daily dismissal after reload', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-03T12:00:00.000Z'));
    mocks.storage.set('dismissedWhatsappUsage::11:2026-10', true);

    const firstWrapper = mountBanner();
    await flushPromises();
    expect(firstWrapper.find('section').exists()).toBe(true);

    await firstWrapper
      .get('button[aria-label="Dismiss WhatsApp usage banner"]')
      .trigger('click');
    firstWrapper.unmount();

    const reloadedWrapper = mountBanner();
    await flushPromises();
    expect(reloadedWrapper.find('section').exists()).toBe(false);
    expect(
      mocks.storage.get('dismissedWhatsappUsage::daily::11:2026-10-03')
    ).toBe(true);

    reloadedWrapper.unmount();
    vi.useRealTimers();
  });

  it('reappears at the next UTC day within the same month with fresh usage', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-02T23:59:59.900Z'));
    mocks.getMonthlyUsage = vi
      .fn()
      .mockResolvedValueOnce(response(monthlyUsage({ month: '2026-10' })))
      .mockResolvedValueOnce(
        response(monthlyUsage({ month: '2026-10', delivered_count: 2 }))
      );

    const wrapper = mountBanner();
    await flushPromises();
    await wrapper
      .get('button[aria-label="Dismiss WhatsApp usage banner"]')
      .trigger('click');

    await vi.advanceTimersByTimeAsync(150);
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(2);
    expect(wrapper.find('section').exists()).toBe(true);
    expect(wrapper.text()).toContain('delivered: 2');

    wrapper.unmount();
    vi.useRealTimers();
  });

  it('ignores a pending old-day response after focus catches up the UTC boundary', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-02T23:58:00.000Z'));
    let resolveOldDay;
    let resolveNextDay;
    mocks.getMonthlyUsage = vi
      .fn()
      .mockResolvedValueOnce(response(monthlyUsage({ delivered_count: 12 })))
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveOldDay = resolve;
          })
      )
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveNextDay = resolve;
          })
      );

    const wrapper = mountBanner();
    await flushPromises();

    vi.setSystemTime(new Date('2026-10-02T23:58:31.000Z'));
    window.dispatchEvent(new Event('focus'));
    await nextTick();
    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(2);

    await wrapper
      .get('button[aria-label="Dismiss WhatsApp usage banner"]')
      .trigger('click');

    vi.setSystemTime(new Date('2026-10-03T00:00:02.000Z'));
    window.dispatchEvent(new Event('focus'));
    await nextTick();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(3);
    expect(wrapper.find('section').exists()).toBe(false);
    expect(wrapper.text()).not.toContain('delivered: 12');

    resolveOldDay(response(monthlyUsage({ delivered_count: 99 })));
    await flushPromises();
    expect(wrapper.find('section').exists()).toBe(false);
    expect(wrapper.text()).not.toContain('delivered: 99');

    resolveNextDay(response(monthlyUsage({ delivered_count: 18 })));
    await flushPromises();
    expect(wrapper.find('section').exists()).toBe(true);
    expect(wrapper.text()).toContain('delivered: 18');

    wrapper.unmount();
    vi.useRealTimers();
  });

  it('preserves a dismissal for one account without suppressing another account', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-03T12:00:00.000Z'));
    mocks.storage.set('dismissedWhatsappUsage::daily::11:2026-10-03', true);
    mocks.getMonthlyUsage = vi.fn(async accountId =>
      response(monthlyUsage({ delivered_count: accountId === 12 ? 28 : 12 }))
    );

    const wrapper = mountBanner();
    await flushPromises();
    expect(wrapper.find('section').exists()).toBe(false);

    mocks.accountId.value = 12;
    await nextTick();
    await flushPromises();

    expect(wrapper.find('section').exists()).toBe(true);
    expect(wrapper.text()).toContain('delivered: 28');
    wrapper.unmount();
    vi.useRealTimers();
  });

  it('reappears with fresh monthly usage at the UTC month boundary', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-31T23:59:59.900Z'));
    mocks.getMonthlyUsage = vi
      .fn()
      .mockResolvedValueOnce(response(monthlyUsage({ month: '2026-10' })))
      .mockResolvedValueOnce(
        response(monthlyUsage({ month: '2026-11', delivered_count: 2 }))
      );

    const wrapper = mountBanner();
    await flushPromises();
    await wrapper
      .get('button[aria-label="Dismiss WhatsApp usage banner"]')
      .trigger('click');

    await vi.advanceTimersByTimeAsync(150);
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(2);
    expect(wrapper.find('section').exists()).toBe(true);
    expect(wrapper.text()).toContain('delivered: 2');

    wrapper.unmount();
    vi.useRealTimers();
  });

  it('clears its UTC day timer on unmount', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-02T23:59:59.000Z'));
    const setTimeoutSpy = vi.spyOn(window, 'setTimeout');
    const clearTimeoutSpy = vi.spyOn(window, 'clearTimeout');

    const wrapper = mountBanner();
    await flushPromises();
    const boundaryTimeoutIndex = setTimeoutSpy.mock.calls.findIndex(
      ([, delay]) => delay === 1000
    );
    expect(boundaryTimeoutIndex).not.toBe(-1);
    const boundaryTimeout =
      setTimeoutSpy.mock.results[boundaryTimeoutIndex].value;

    wrapper.unmount();
    expect(clearTimeoutSpy).toHaveBeenCalledWith(boundaryTimeout);
    await vi.advanceTimersByTimeAsync(1100);
    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(1);

    setTimeoutSpy.mockRestore();
    clearTimeoutSpy.mockRestore();
    vi.useRealTimers();
  });

  it('refreshes visible eligible usage and stops polling after dismissal', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-02T00:00:00.000Z'));
    const visibilityDescriptor = Object.getOwnPropertyDescriptor(
      document,
      'visibilityState'
    );
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      value: 'visible',
    });
    mocks.getMonthlyUsage = vi
      .fn()
      .mockResolvedValueOnce(response(monthlyUsage()))
      .mockResolvedValueOnce(response(monthlyUsage({ delivered_count: 21 })));

    const wrapper = mountBanner();
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(60_000);
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(2);
    expect(wrapper.text()).toContain('delivered: 21');

    await wrapper
      .get('button[aria-label="Dismiss WhatsApp usage banner"]')
      .trigger('click');
    await vi.advanceTimersByTimeAsync(120_000);
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(2);

    wrapper.unmount();
    if (visibilityDescriptor) {
      Object.defineProperty(document, 'visibilityState', visibilityDescriptor);
    } else {
      delete document.visibilityState;
    }
    vi.useRealTimers();
  });

  it('hides prior usage after a 403 for the same account', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-02T00:00:00.000Z'));

    const initialRequest = mocks.getMonthlyUsage;
    const wrapper = mountBanner();
    await flushPromises();

    expect(wrapper.find('section').exists()).toBe(true);
    expect(wrapper.text()).toContain('delivered: 12');

    mocks.getMonthlyUsage = vi.fn(async () => {
      throw Object.assign(new Error('Forbidden'), {
        response: { status: 403 },
      });
    });
    vi.setSystemTime(new Date('2026-10-02T00:00:30.001Z'));
    window.dispatchEvent(new Event('focus'));
    await flushPromises();

    expect(initialRequest).toHaveBeenCalledTimes(1);
    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(1);
    expect(wrapper.find('section').exists()).toBe(false);
    expect(wrapper.text()).not.toContain('delivered: 12');

    wrapper.unmount();
    vi.useRealTimers();
  });

  it('ignores stale data after switching accounts and hides on access failure', async () => {
    let resolveFirstAccount;
    mocks.getMonthlyUsage = vi.fn(accountId => {
      if (accountId === 11) {
        return new Promise(resolve => {
          resolveFirstAccount = resolve;
        });
      }
      return Promise.resolve(response(monthlyUsage({ delivered_count: 22 })));
    });

    const wrapper = mountBanner();
    mocks.accountId.value = 12;
    await nextTick();
    await flushPromises();

    resolveFirstAccount(response(monthlyUsage({ delivered_count: 99 })));
    await flushPromises();
    expect(wrapper.text()).toContain('delivered: 22');
    expect(wrapper.text()).not.toContain('delivered: 99');

    mocks.getMonthlyUsage = vi.fn(async () => {
      throw Object.assign(new Error('Forbidden'), {
        response: { status: 403 },
      });
    });
    mocks.accountId.value = 13;
    await nextTick();
    await flushPromises();

    expect(wrapper.find('section').exists()).toBe(false);

    wrapper.unmount();
  });
});
