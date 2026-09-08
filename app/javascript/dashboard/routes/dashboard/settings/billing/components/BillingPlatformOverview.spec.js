import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import BillingPlatformOverview from './BillingPlatformOverview.vue';

const { getMock } = vi.hoisted(() => ({ getMock: vi.fn() }));

vi.mock('dashboard/api/billingOverview', () => ({
  default: { get: getMock },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
    locale: ref('en'),
  }),
}));

const overview = {
  configured: true,
  billing_account: {
    name: 'Acme Billing',
    workspace_count: 2,
    unique_user_count: 4,
  },
  subscription: {
    status: 'active',
    current_period_ends_at: '2026-10-04T00:00:00Z',
    plan: { name: 'Growth' },
  },
  limits: [
    {
      key: 'agents',
      value: 10,
      consumed: 4,
      unlimited: false,
      source: 'billing_allocation',
    },
  ],
};

const mountComponent = () =>
  mount(BillingPlatformOverview, {
    global: {
      stubs: {
        BillingCard: {
          props: ['title', 'description'],
          template:
            '<section>{{ title }} {{ description }}<slot name="action"/><slot/></section>',
        },
        BillingMeter: {
          props: ['title', 'displayConsumed', 'displayTotal'],
          template:
            '<div>{{ title }} {{ displayConsumed }} / {{ displayTotal }}</div>',
        },
        DetailItem: {
          props: ['label', 'value'],
          template: '<div>{{ label }}: {{ value }}</div>',
        },
        ButtonV4: { template: '<button><slot/></button>' },
      },
    },
  });

describe('BillingPlatformOverview', () => {
  beforeEach(() => {
    getMock.mockReset();
  });

  it('renders organization, subscription, allocation, and source', async () => {
    getMock.mockResolvedValue({ data: overview });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.emitted('loaded')).toEqual([[true]]);
    expect(wrapper.text()).toContain('Acme Billing');
    expect(wrapper.text()).toContain('Growth');
    expect(wrapper.text()).toContain(
      'BILLING_SETTINGS.PLATFORM.STATUSES.ACTIVE'
    );
    expect(wrapper.text()).toContain('4 / 10');
    expect(wrapper.text()).toContain(
      'BILLING_SETTINGS.PLATFORM.SOURCE.BILLING_ALLOCATION'
    );
  });

  it('renders the legacy transition state for an unlinked workspace', async () => {
    getMock.mockResolvedValue({ data: { ...overview, configured: false } });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.emitted('loaded')).toEqual([[false]]);
    expect(wrapper.text()).toContain(
      'This workspace still uses legacy limits. A billing organization has not been connected yet.'
    );
  });

  it('keeps an API failure explicit and supports retry', async () => {
    getMock
      .mockRejectedValueOnce(new Error('network'))
      .mockResolvedValueOnce({ data: overview });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain('Could not load plan data.');
    expect(wrapper.emitted('loaded')).toBeUndefined();

    await wrapper.get('button').trigger('click');
    await flushPromises();

    expect(getMock).toHaveBeenCalledTimes(2);
    expect(wrapper.emitted('loaded')).toEqual([[true]]);
  });
});
