import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import TaskSettings from './TaskSettings.vue';

const testState = vi.hoisted(() => ({
  loadTaskTypes: vi.fn(() => Promise.resolve()),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => true }),
}));

vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => ({
    ui: { error: null, isLoadingTaskTypes: false },
    loadTaskTypes: testState.loadTaskTypes,
  }),
}));

vi.mock('../components/BaseSettingsHeader.vue', () => ({
  default: { template: '<header />' },
}));

vi.mock('../SettingsLayout.vue', () => ({
  default: { template: '<main><slot name="body" /><slot /></main>' },
}));

const mountComponent = () =>
  mount(TaskSettings, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        CrmTaskCatalogSettings: {
          template: '<section data-testid="task-catalog" />',
        },
        SchedulingErrorState: true,
        Spinner: true,
      },
    },
  });

describe('TaskSettings', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('loads the task catalog without loading or managing statuses', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    expect(testState.loadTaskTypes).toHaveBeenCalledWith({
      include_inactive: true,
    });
    expect(wrapper.find('[data-testid="task-catalog"]').exists()).toBe(true);
    expect(wrapper.text()).not.toContain('CRM.SETTINGS.TASK_STATUSES');
    expect(wrapper.find('select').exists()).toBe(false);
  });
});
