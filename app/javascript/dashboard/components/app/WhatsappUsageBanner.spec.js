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
            'WhatsApp Cloud · this UTC month: {deliveredCount} · total ≈ {amount}',
          'WHATSAPP_USAGE.BANNER_DETAILS':
            'Templates: {templateCount} · unpriced: {unpricedCount} · unknown: {unknownCount}',
          'WHATSAPP_USAGE.BANNER_TOOLTIP':
            'Service messages {serviceAmount}; templates {templateAmount}; rate month {rateMonth}; requested {requestedDate}; effective {effectiveDate}; {rate} KZT per USD; before volume discounts. Unpriced: {unpricedCount}; unknown: {unknownCount}.',
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
  service_delivered_count: 8,
  template_delivered_count: 3,
  chargeable_service_count: 6,
  chargeable_template_count: 2,
  chargeable_message_count: 8,
  unpriced_billable_count: 0,
  unknown_billable_count: 0,
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
const MAX_TIMEOUT_DELAY = 2 ** 31 - 1;

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
    expect(wrapper.text()).toContain('this UTC month: 12');
    expect(wrapper.get('p').text()).toContain('total ≈');
    expect(wrapper.get('p').text()).toContain('74.75');
    expect(wrapper.text()).toContain('Templates: 3 · unpriced: 2 · unknown: 1');
    expect(wrapper.text()).toContain('Estimate incomplete');
    expect(wrapper.text()).not.toContain('Template cost separate');
    const tooltip = wrapper
      .get('[title]')
      .attributes('title')
      .replace(/\s+/g, ' ');
    expect(tooltip).toContain('Service messages KZT 64.25; templates KZT 10.5');
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

    expect(wrapper.get('p').text().replace(/\s+/g, ' ')).toContain(
      'total ≈ KZT 0'
    );
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

    expect(wrapper.get('p').text()).toContain('total ≈ unavailable');
    expect(wrapper.text()).toContain('Estimate incomplete');
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

    expect(
      wrapper.get('[title]').attributes('title').replace(/\s+/g, ' ')
    ).toContain('templates KZT 350');
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

    expect(wrapper.get('p').text()).toContain('total ≈ unavailable');
    expect(wrapper.get('p').text()).not.toContain('KZT 0');
    expect(wrapper.text()).toContain('Estimate incomplete');
    expect(wrapper.get('[title]').attributes('title')).toContain(
      'effective unavailable; unavailable KZT per USD'
    );

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

    expect(wrapper.text()).toContain('unpriced: — · unknown: —');
    expect(wrapper.text()).toContain('Estimate incomplete');

    wrapper.unmount();
  });

  it('stores dismissal by account and month and shows another account', async () => {
    const wrapper = mountBanner();
    await flushPromises();

    await wrapper.find('button').trigger('click');
    expect(mocks.storage.get('dismissedWhatsappUsage::11:2026-10')).toBe(true);
    expect(wrapper.find('section').exists()).toBe(false);

    mocks.getMonthlyUsage = vi.fn(async accountId =>
      response(monthlyUsage({ delivered_count: accountId === 12 ? 28 : 12 }))
    );
    mocks.accountId.value = 12;
    await nextTick();
    await flushPromises();

    expect(wrapper.text()).toContain('this UTC month: 28');
    expect(wrapper.find('section').exists()).toBe(true);

    wrapper.unmount();
  });

  it('reappears after the UTC month boundary', async () => {
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
    await wrapper.find('button').trigger('click');

    await vi.advanceTimersByTimeAsync(150);
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(2);
    expect(wrapper.find('section').exists()).toBe(true);
    expect(wrapper.text()).toContain('this UTC month: 2');

    wrapper.unmount();
    vi.useRealTimers();
  });

  it('chunks a long wait for the UTC month boundary without refreshing early', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-02T00:00:00.000Z'));
    const visibilityDescriptor = Object.getOwnPropertyDescriptor(
      document,
      'visibilityState'
    );
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      value: 'hidden',
    });
    const setTimeoutSpy = vi.spyOn(window, 'setTimeout');
    mocks.getMonthlyUsage = vi
      .fn()
      .mockResolvedValueOnce(response(monthlyUsage({ month: '2026-10' })))
      .mockResolvedValueOnce(
        response(monthlyUsage({ month: '2026-11', delivered_count: 2 }))
      );

    const wrapper = mountBanner();
    await flushPromises();

    expect(setTimeoutSpy).toHaveBeenCalledWith(
      expect.any(Function),
      MAX_TIMEOUT_DELAY
    );
    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(MAX_TIMEOUT_DELAY);
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(1);
    expect(wrapper.text()).toContain('this UTC month: 12');

    const untilNextMonth = Date.UTC(2026, 10, 1) - Date.now();
    await vi.advanceTimersByTimeAsync(untilNextMonth);
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledTimes(2);
    expect(wrapper.text()).toContain('this UTC month: 2');

    wrapper.unmount();
    if (visibilityDescriptor) {
      Object.defineProperty(document, 'visibilityState', visibilityDescriptor);
    } else {
      delete document.visibilityState;
    }
    setTimeoutSpy.mockRestore();
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
    expect(wrapper.text()).toContain('this UTC month: 21');

    await wrapper.find('button').trigger('click');
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
    expect(wrapper.text()).toContain('this UTC month: 12');

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
    expect(wrapper.text()).not.toContain('this UTC month: 12');

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
    expect(wrapper.text()).toContain('this UTC month: 22');
    expect(wrapper.text()).not.toContain('this UTC month: 99');

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
