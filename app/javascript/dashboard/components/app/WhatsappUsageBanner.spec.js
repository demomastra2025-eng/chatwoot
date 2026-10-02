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
            'WhatsApp Cloud · this UTC month: {deliveredCount} · service ≈ {amount}',
          'WHATSAPP_USAGE.BANNER_DETAILS':
            'Templates: {templateCount} · unknown: {unknownCount} · UTC',
          'WHATSAPP_USAGE.TEMPLATE_COSTS_SEPARATE': 'Template cost separate',
          'WHATSAPP_USAGE.BANNER_TOOLTIP':
            'Delivered count includes all messages this UTC month. The approximate amount is only the service-message subtotal; template prices and unknown-category message costs are excluded. Missing timestamps or billing data may make it incomplete. Meta free allowance is not subtracted again.',
          'WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE': 'unavailable',
          'WHATSAPP_USAGE.ESTIMATE_INCOMPLETE': 'Monthly data incomplete',
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
  unknown_category_delivered_count: 1,
  unknown_delivery_timestamp_count: 0,
  chargeable_service_count: 0,
  estimated_amount_kzt: 0,
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

  it('shows total delivered volume and labels the estimate as service-only', async () => {
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(
        monthlyUsage({
          service_delivered_count: 1008,
          chargeable_service_count: 8,
          estimated_amount_kzt: 64,
          coverage_complete: false,
          service_estimate_complete: false,
        })
      )
    );

    const wrapper = mountBanner();
    await flushPromises();

    expect(mocks.getMonthlyUsage).toHaveBeenCalledWith(11);
    expect(wrapper.text()).toContain('this UTC month: 12');
    expect(wrapper.text()).toContain('64');
    expect(wrapper.text()).toContain('Templates: 3 · unknown: 1 · UTC');
    expect(wrapper.text()).toContain('Template cost separate');
    expect(wrapper.text()).toContain('Monthly data incomplete');
    expect(wrapper.get('[title]').attributes('title')).toContain(
      'template prices and unknown-category message costs are excluded'
    );
    expect(wrapper.get('[title]').attributes('title')).toContain(
      'Meta free allowance is not subtracted again'
    );
    expect(wrapper.find('section[role="status"]').exists()).toBe(true);
    expect(
      wrapper
        .find('button[aria-label="Dismiss WhatsApp usage banner"]')
        .exists()
    ).toBe(true);

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

  it('hides accounts without an eligible official Cloud WhatsApp phone', async () => {
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(monthlyUsage({ eligible: false, official_cloud_phone_count: 0 }))
    );

    const wrapper = mountBanner();
    await flushPromises();

    expect(wrapper.find('section').exists()).toBe(false);

    wrapper.unmount();
  });

  it('does not mark complete service coverage incomplete only for template costs', async () => {
    mocks.getMonthlyUsage = vi.fn(async () =>
      response(
        monthlyUsage({
          template_delivered_count: 3,
          unknown_category_delivered_count: 0,
          coverage_complete: true,
          service_estimate_complete: true,
          estimate_complete: false,
        })
      )
    );

    const wrapper = mountBanner();
    await flushPromises();

    expect(wrapper.text()).toContain('Template cost separate');
    expect(wrapper.text()).not.toContain('Monthly data incomplete');
    expect(wrapper.find('section').exists()).toBe(true);

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
