import { describe, it, expect, vi, beforeEach } from 'vitest';
import { mount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import { createI18n } from 'vue-i18n';
import ruContact from 'dashboard/i18n/locale/ru/contact.json';
import ContactsDuplicates from './ContactsDuplicates.vue';
import ContactAPI from 'dashboard/api/contacts';

const mockAlert = vi.fn();
vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mockAlert(...args),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '1' } }),
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock('dashboard/api/contacts', () => ({
  default: {
    getDuplicates: vi.fn(),
    dismissDuplicate: vi.fn(),
  },
}));

const createTestI18n = () =>
  createI18n({
    legacy: false,
    locale: 'ru',
    messages: {
      ru: ruContact,
    },
  });

describe('ContactsDuplicates', () => {
  let mergeAction;
  let store;

  beforeEach(() => {
    mockAlert.mockReset();
    mergeAction = vi.fn().mockResolvedValue({});
    store = createStore({
      modules: {
        contacts: {
          namespaced: true,
          actions: {
            merge: mergeAction,
          },
        },
      },
    });

    ContactAPI.getDuplicates.mockResolvedValue({
      data: {
        payload: [
          {
            id: '101-202',
            match_reasons: ['shared_phone'],
            primary_contact: {
              id: 101,
              name: 'Алия Серикова',
              phone_number: '+77011112233',
              conversations_count: 3,
              appointments_count: 2,
              deals_count: 0,
              call_sessions_count: 0,
            },
            conflicting_contact: {
              id: 202,
              name: 'Алия С.',
              phone_number: '+77011112233',
              conversations_count: 0,
              appointments_count: 0,
              deals_count: 0,
              call_sessions_count: 0,
            },
          },
        ],
      },
    });
    ContactAPI.dismissDuplicate.mockResolvedValue({});
  });

  const mountComponent = () =>
    mount(ContactsDuplicates, {
      global: {
        plugins: [store, createTestI18n()],
      },
    });

  it('renders compact row, collapses non-zero counters into a single pill, and hides zero counters', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const rows = wrapper.findAll('[data-testid="duplicate-pair-row"]');
    expect(rows).toHaveLength(1);

    const pills = wrapper.findAll('[data-testid="contact-activity-pill"]');
    // Only primary_contact has non-zero activity; conflicting_contact has all zeros so its pill is hidden
    expect(pills).toHaveLength(1);
    expect(pills[0].text()).toBe('Диалоги: 3 · Записи: 2');
    expect(wrapper.text()).not.toContain('Сделки: 0');
    expect(wrapper.text()).not.toContain('Звонки: 0');
  });

  it('allows swapping primary contact and merging with a single Merge button', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    // Swap primary to right contact (id: 202)
    await wrapper.find('[data-testid="swap-primary-btn"]').trigger('click');
    await wrapper.find('[data-testid="merge-pair-btn"]').trigger('click');
    await flushPromises();

    expect(mergeAction).toHaveBeenCalledTimes(1);
    expect(mergeAction.mock.calls[0][1]).toEqual({
      parentId: 202,
      childId: 101,
    });
  });

  it('dismisses duplicate pair when clicking Not duplicate', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.find('[data-testid="dismiss-pair-btn"]').trigger('click');
    await flushPromises();

    expect(ContactAPI.dismissDuplicate).toHaveBeenCalledWith(101, 202);
    expect(wrapper.findAll('[data-testid="duplicate-pair-row"]')).toHaveLength(
      0
    );
  });
});
