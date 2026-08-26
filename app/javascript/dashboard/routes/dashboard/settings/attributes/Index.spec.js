import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

import Index from './Index.vue';

const { dispatch, getAttributesByModel, loadFieldDefinitions } = vi.hoisted(
  () => ({
    dispatch: vi.fn(() => Promise.resolve()),
    getAttributesByModel: vi.fn(() => []),
    loadFieldDefinitions: vi.fn(() => Promise.resolve([])),
  })
);

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('@scmmishra/pico-search', () => ({
  picoSearch: items => items,
}));

const enabledFeatures = new Set([
  'companies',
  'crm',
  'crm_deals',
  'crm_tasks',
  'custom_attributes',
  'scheduling',
]);

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
  useStoreGetters: () => ({
    'attributes/getUIFlags': ref({ isFetching: false }),
    'attributes/getAttributesByModel': ref(getAttributesByModel),
  }),
  useMapGetter: key => {
    if (key === 'accounts/isFeatureEnabledonAccount') {
      return ref((_accountId, feature) => enabledFeatures.has(feature));
    }
    if (key === 'getCurrentAccountId') {
      return ref(1);
    }
    if (key === 'inboxes/getInboxes') {
      return ref([]);
    }
    return ref(null);
  },
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount: ref({ settings: {} }),
  }),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({
    checkPermissions: permissions => permissions.includes('administrator'),
  }),
}));

vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => ({
    appointmentFieldDefinitions: [],
    dealFieldDefinitions: [],
    taskFieldDefinitions: [],
    ui: { isLoadingFieldDefinitions: false, isSaving: false },
    loadFieldDefinitions,
  }),
}));

const mountComponent = (props = {}) =>
  shallowMount(Index, {
    props,
    global: {
      stubs: {
        AddAttribute: true,
        AttributeListItem: true,
        BaseSettingsHeader: {
          props: ['title'],
          template:
            '<section><h1>{{ title }}</h1><slot name="count" /><slot name="tabs" /><slot name="actions" /></section>',
        },
        Button: true,
        Dialog: true,
        EditAttribute: true,
        SettingsLayout: {
          template:
            '<main><slot name="header" /><slot name="body" /><slot /></main>',
        },
        TabBar: {
          props: ['tabs'],
          template:
            '<nav><span v-for="tab in tabs" :key="tab.key">{{ tab.label }}</span></nav>',
        },
        WootConfirmDeleteModal: true,
        WootModal: true,
      },
    },
  });

describe('Attributes settings index', () => {
  it('exposes company custom attributes as a first-class legacy CRUD tab', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('ATTRIBUTES_MGMT.TABS.CONVERSATION');
    expect(wrapper.text()).toContain('ATTRIBUTES_MGMT.TABS.CONTACT');
    expect(wrapper.text()).toContain('ATTRIBUTES_MGMT.TABS.COMPANY');
  });

  it('can be scoped to contact additional fields for domain settings', () => {
    const wrapper = mountComponent({
      initialTab: 'contact_attribute',
      tabs: ['contact_attribute'],
    });

    expect(wrapper.text()).not.toContain('ATTRIBUTES_MGMT.TABS.CONVERSATION');
    expect(wrapper.text()).toContain('Additional Fields');
    expect(wrapper.text()).not.toContain('ATTRIBUTES_MGMT.TABS.COMPANY');
  });

  it('locks the legacy model selector when scoped to one domain tab', () => {
    const wrapper = mountComponent({
      initialTab: 'contact_attribute',
      tabs: ['contact_attribute'],
    });

    expect(wrapper.vm.selectedLegacyTabIndex).toBe(1);
    expect(wrapper.vm.disableLegacyAttributeModelSelection).toBe(true);
  });

  it('can be scoped to task CRM fields without offering entity switching', () => {
    const wrapper = mountComponent({
      initialTab: 'task',
      tabs: ['task'],
    });

    expect(wrapper.vm.crmEntityOptions).toEqual([
      { label: 'CRM.SETTINGS.FIELD_TABS.TASKS', value: 'task' },
    ]);
  });

  it('shows the five workspace entities and follows a route-driven tab change', async () => {
    const tabs = [
      'conversation_attribute',
      'contact_attribute',
      'company_attribute',
      'deal',
      'task',
    ];
    const wrapper = mountComponent({ initialTab: 'deal', tabs });

    expect(wrapper.vm.availableTabs.map(tab => tab.key)).toEqual(tabs);
    expect(wrapper.vm.selectedTabKey).toBe('deal');

    await wrapper.setProps({ initialTab: 'task' });

    expect(wrapper.vm.selectedTabKey).toBe('task');
  });
});
