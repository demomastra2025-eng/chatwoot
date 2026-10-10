import { flushPromises, shallowMount } from '@vue/test-utils';
import { useAlert } from 'dashboard/composables';
import { useStore, useStoreGetters } from 'dashboard/composables/store';
import AutomationSettings from './Index.vue';
import russianAutomation from 'dashboard/i18n/locale/ru/automation.json';

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: vi.fn(),
  useStoreGetters: vi.fn(),
}));

const mountComponent = ({ dispatch = vi.fn() } = {}) => {
  useStore.mockReturnValue({ dispatch });
  useStoreGetters.mockReturnValue({
    'automations/getAutomations': { value: [] },
    'automations/getUIFlags': { value: { isFetching: false } },
    getCurrentAccountId: { value: 1 },
    'accounts/isFeatureEnabledonAccount': { value: () => false },
  });

  return shallowMount(AutomationSettings, {
    global: {
      mocks: {
        $t: key =>
          key
            .split('.')
            .reduce((value, part) => value?.[part], russianAutomation) || key,
      },
      stubs: {
        AddAutomationRule: {
          template:
            "<button data-test=\"add\" @click=\"$emit('save-automation', { name: 'Rule' }, 'create')\" />",
        },
        BaseSettingsHeader: { template: '<div><slot name="actions" /></div>' },
        BaseTable: { template: '<div />' },
        Button: { template: '<button @click="$emit(\'click\')" />' },
        EditAutomationRule: true,
        SettingsLayout: {
          template:
            '<div><slot name="header" /><slot name="body" /><slot /></div>',
        },
        'woot-confirm-modal': {
          props: ['confirmLabel', 'cancelLabel'],
          template:
            '<div data-test="toggle-confirmation"><button>{{ confirmLabel }}</button><button>{{ cancelLabel }}</button></div>',
        },
        'woot-delete-modal': true,
      },
    },
  });
};

describe('Automation settings', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('shows API validation text when automation save fails', async () => {
    const dispatch = vi.fn(action => {
      if (action === 'automations/create') {
        const error = new Error('Validation failed');
        error.response = { data: { error: 'Stage is archived' } };
        return Promise.reject(error);
      }
      return Promise.resolve();
    });
    const wrapper = mountComponent({ dispatch });

    await wrapper.find('[data-test="add"]').trigger('click');
    await flushPromises();

    expect(useAlert).toHaveBeenCalledWith('Stage is archived');
  });

  it('uses the existing Russian yes and no labels for activation and deactivation', () => {
    const wrapper = mountComponent();

    expect(
      wrapper
        .find('[data-test="toggle-confirmation"]')
        .findAll('button')
        .map(button => button.text())
    ).toEqual(['Да', 'Нет']);
  });
});
