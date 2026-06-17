import { flushPromises, shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { useI18n } from 'vue-i18n';

import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import ContactsForm from './ContactsForm.vue';

const companiesStore = vi.hoisted(() => ({
  getCompaniesList: [],
  get: vi.fn(),
  search: vi.fn(),
}));

vi.mock('vue-i18n');
vi.mock('@chatwoot/utils', async () => {
  const actual = await vi.importActual('@chatwoot/utils');
  return {
    ...actual,
    debounce: fn => fn,
  };
});
vi.mock('dashboard/stores/companies', () => ({
  useCompaniesStore: () => companiesStore,
}));

const mountComponent = props =>
  shallowMount(ContactsForm, {
    props: {
      contactData: {
        id: 1,
        name: 'Jane Doe',
        email: 'jane@example.com',
        phoneNumber: '+77001234567',
        additionalAttributes: {},
      },
      ...props,
    },
  });

const findCompanyComboBox = wrapper =>
  wrapper
    .findAllComponents(ComboBox)
    .find(comboBox =>
      comboBox.props('options').some(option => option.label === 'Acme Clinic')
    );

describe('ContactsForm', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    companiesStore.getCompaniesList = [
      { id: 7, name: 'Acme Clinic' },
      { id: 8, name: 'Beta Care' },
    ];
    useI18n.mockReturnValue({ t: key => key });
  });

  it('renders the selected native company in the organization selector', () => {
    const wrapper = mountComponent({
      contactData: {
        id: 1,
        name: 'Jane Doe',
        companyId: 7,
        company: { id: 7, name: 'Acme Clinic' },
        additionalAttributes: { companyName: 'Legacy Org' },
      },
    });

    const companyComboBox = findCompanyComboBox(wrapper);

    expect(companyComboBox.props('modelValue')).toBe(7);
    expect(companyComboBox.props('options')).toContainEqual({
      label: 'Acme Clinic',
      value: 7,
    });
  });

  it('emits companyId and legacy companyName when a company is selected', async () => {
    const wrapper = mountComponent();
    const companyComboBox = findCompanyComboBox(wrapper);

    await companyComboBox.vm.$emit('update:modelValue', 7);
    await flushPromises();

    expect(wrapper.emitted('update').at(-1)[0]).toMatchObject({
      companyId: 7,
      additionalAttributes: { companyName: 'Acme Clinic' },
    });
  });

  it('loads and searches companies through the company store', async () => {
    const wrapper = mountComponent();
    const companyComboBox = findCompanyComboBox(wrapper);

    await companyComboBox.vm.$emit('open');
    await companyComboBox.vm.$emit('search', 'acme');

    expect(companiesStore.get).toHaveBeenCalledWith({ page: 1, sort: 'name' });
    expect(companiesStore.search).toHaveBeenCalledWith({
      search: 'acme',
      page: 1,
      sort: 'name',
    });
  });
});
