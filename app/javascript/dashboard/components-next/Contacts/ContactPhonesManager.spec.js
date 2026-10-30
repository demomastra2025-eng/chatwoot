import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { createPinia } from 'pinia';
import contactRu from 'dashboard/i18n/locale/ru/contact.json';
import ContactPhonesAPI from 'dashboard/api/contactPhones';
import ContactPhonesManager from './ContactPhonesManager.vue';

const dispatchMock = vi.fn();

vi.mock('dashboard/api/contactPhones', () => ({
  default: {
    create: vi.fn(),
    setPrimary: vi.fn(),
    destroy: vi.fn(),
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '530' } }),
}));

vi.mock('vuex', () => ({
  useStore: () => ({
    getters: { getCurrentAccountId: 530 },
    dispatch: dispatchMock,
  }),
}));

const translate = (key, params = {}) => {
  const raw = key.split('.').reduce((acc, part) => acc?.[part], contactRu);
  if (!raw) return key;
  return Object.entries(params).reduce(
    (str, [k, v]) => str.replace(`{${k}}`, v),
    raw
  );
};

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: translate }),
}));

const mountManager = (contact, extraProps = {}) =>
  mount(ContactPhonesManager, {
    props: { contact, ...extraProps },
    global: {
      plugins: [createPinia()],
      mocks: { $t: translate },
      stubs: {
        RouterLink: {
          name: 'RouterLink',
          props: ['to'],
          template: '<a :href="to"><slot /></a>',
        },
        PhoneNumberInput: {
          name: 'PhoneNumberInput',
          props: ['modelValue'],
          emits: ['update:modelValue'],
          template: `<input data-testid="phone-input-stub" :value="modelValue" @input="$emit('update:modelValue', $event.target.value)" />`,
        },
      },
    },
  });

describe('ContactPhonesManager', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('displays shared family phone with clickable owner and peer links so shared-phone cards never look empty', () => {
    const wrapper = mountManager({
      id: 201,
      name: 'Серик',
      phoneNumber: null,
      phoneNumbers: [
        {
          id: 11,
          phoneNumber: '+77020001122',
          primary: false,
          shared: true,
          ownerContactId: 100,
          ownerContact: { id: 100, name: 'Алия' },
          sharedContacts: [{ id: 202, name: 'Амина' }],
        },
      ],
    });

    expect(wrapper.get('[data-testid="contact-phone-row"]').text()).toContain(
      '+77020001122'
    );
    expect(wrapper.get('[data-testid="contact-phone-badge"]').text()).toBe(
      'общий'
    );
    const ownerLink = wrapper.get('[data-testid="contact-phone-owner-link"]');
    expect(ownerLink.text()).toBe('Алия');
    expect(ownerLink.attributes('href')).toBe('/app/accounts/530/contacts/100');
    const peerLink = wrapper.get(
      '[data-testid="contact-phone-shared-peer-link"]'
    );
    expect(peerLink.text()).toBe('Амина');
    expect(peerLink.attributes('href')).toBe('/app/accounts/530/contacts/202');
  });

  it('offers one-click shared family linking when POST /phones returns 409 PHONE_OWNED_BY_OTHER_CONTACT', async () => {
    ContactPhonesAPI.create
      .mockRejectedValueOnce({
        response: {
          status: 409,
          data: {
            code: 'PHONE_OWNED_BY_OTHER_CONTACT',
            phone_number: '+77020001122',
            can_link_shared: true,
            owner_contact: { id: 100, name: 'Алия' },
          },
        },
      })
      .mockResolvedValueOnce({
        data: {
          payload: {
            id: 205,
            phone_number: '+77010009988',
            phone_numbers: [],
          },
        },
      });

    const wrapper = mountManager({
      id: 205,
      name: 'Муж',
      phone_number: '+77010009988',
      phone_numbers: [
        {
          id: 1,
          phone_number: '+77010009988',
          primary: true,
          shared: false,
        },
      ],
    });

    await wrapper
      .get('[data-testid="contact-phones-add-trigger"]')
      .trigger('click');
    await wrapper
      .get('[data-testid="phone-input-stub"]')
      .setValue('+77020001122');
    await wrapper
      .get('[data-testid="contact-phones-add-form"]')
      .trigger('submit.prevent');
    await flushPromises();

    const banner = wrapper.get('[data-testid="contact-phone-conflict-banner"]');
    expect(banner.text()).toContain('+77020001122');
    expect(
      wrapper.get('[data-testid="contact-phone-conflict-owner-link"]').text()
    ).toBe('Алия');

    await wrapper
      .get('[data-testid="contact-phone-link-shared-confirm"]')
      .trigger('click');
    await flushPromises();

    expect(ContactPhonesAPI.create).toHaveBeenNthCalledWith(2, 205, {
      phone_number: '+77020001122',
      label: undefined,
      link_shared: true,
    });
  });

  it('preserves ownerContact router-link even if a partial list update omits owner_contact', async () => {
    const wrapper = mountManager({
      id: 201,
      name: 'Серик',
      phone_numbers: [
        {
          id: 11,
          phone_number: '+77020001122',
          primary: false,
          shared: true,
          owner_contact_id: 100,
          owner_contact: { id: 100, name: 'Алия' },
          shared_contacts: [],
        },
      ],
    });

    expect(wrapper.get('[data-testid="contact-phone-owner-link"]').text()).toBe(
      'Алия'
    );

    await wrapper.setProps({
      contact: {
        id: 201,
        name: 'Серик',
        phone_numbers: [
          {
            id: 11,
            phone_number: '+77020001122',
            primary: false,
            shared: true,
            owner_contact_id: 100,
            owner_contact: null,
            shared_contacts: [],
          },
        ],
      },
    });

    expect(wrapper.get('[data-testid="contact-phone-owner-link"]').text()).toBe(
      'Алия'
    );
  });
});
