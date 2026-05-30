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

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
  useStoreGetters: () => ({
    'attributes/getUIFlags': ref({ isFetching: false }),
    'attributes/getAttributesByModel': ref(getAttributesByModel),
  }),
  useMapGetter: key => {
    if (key === 'accounts/isFeatureEnabledonAccount') {
      return ref((_accountId, feature) => feature === 'custom_attributes');
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

const mountComponent = () =>
  shallowMount(Index, {
    global: {
      stubs: {
        AddAttribute: true,
        AttributeListItem: true,
        BaseSettingsHeader: {
          template:
            '<section><slot name="count" /><slot name="tabs" /><slot name="actions" /></section>',
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
});
