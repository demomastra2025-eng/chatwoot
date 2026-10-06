import { flushPromises, mount } from '@vue/test-utils';
import { h, ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import TaskSettings from './TaskSettings.vue';

const testState = vi.hoisted(() => ({
  loadTaskStatuses: vi.fn(() => Promise.resolve()),
  loadTaskTypes: vi.fn(() => Promise.resolve()),
  saveTaskStatus: vi.fn(() => Promise.resolve()),
  useAlert: vi.fn(),
  route: { query: {} },
  router: { replace: vi.fn(() => Promise.resolve()), push: vi.fn() },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => testState.route,
  useRouter: () => testState.router,
}));

vi.mock('dashboard/composables', () => ({
  useAlert: testState.useAlert,
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => true }),
}));

vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => ({
    taskStatuses: [
      { id: 1, name: 'To do', category: 'open', active: true, position: 0 },
      {
        id: 2,
        name: 'Dropped',
        category: 'cancelled',
        active: true,
        position: 1,
      },
    ],
    ui: { error: null, isLoadingTaskStatuses: false, isSaving: false },
    loadTaskStatuses: testState.loadTaskStatuses,
    loadTaskTypes: testState.loadTaskTypes,
    saveTaskStatus: testState.saveTaskStatus,
  }),
}));

// The real layout pulls in the app router through BackButton.
vi.mock('../components/BaseSettingsHeader.vue', () => ({
  default: { template: '<header />' },
}));

vi.mock('../SettingsLayout.vue', () => ({
  default: { template: '<main><slot name="body" /><slot /></main>' },
}));

const ButtonStub = {
  props: { label: { type: String, default: '' } },
  emits: ['click'],
  template:
    '<button type="button" @click="$emit(\'click\')">{{ label }}</button>',
};

const DraggableStub = {
  props: { modelValue: { type: Array, default: () => [] } },
  setup(props, { slots }) {
    return () =>
      h(
        'div',
        props.modelValue.map((element, index) =>
          slots.item?.({ element, index })
        )
      );
  },
};

const SchedulingDrawerStub = {
  props: {
    modelValue: { type: Boolean, default: false },
    title: { type: String, default: '' },
  },
  template:
    '<aside v-if="modelValue" data-testid="status-drawer">{{ title }}<slot /></aside>',
};

const mountComponent = () =>
  mount(TaskSettings, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        Button: ButtonStub,
        Checkbox: true,
        CrmTaskCatalogSettings: {
          template: '<section data-testid="task-catalog" />',
        },
        Dialog: true,
        Draggable: DraggableStub,
        Input: true,
        SchedulingColorPicker: true,
        SchedulingDrawer: SchedulingDrawerStub,
        SchedulingErrorState: true,
        SchedulingFormFieldGroup: {
          props: { title: { type: String, default: '' } },
          template:
            '<section><h3>{{ title }}</h3><slot /><slot name="headerActions" /></section>',
        },
        SchedulingSelectField: true,
        Spinner: true,
        Switch: true,
      },
    },
  });

describe('TaskSettings', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    testState.route.query = {};
  });

  it('loads statuses and task types on mount', async () => {
    mountComponent();
    await flushPromises();

    expect(testState.loadTaskStatuses).toHaveBeenCalled();
    expect(testState.loadTaskTypes).toHaveBeenCalledWith({
      include_inactive: true,
    });
  });

  it('shows the statuses and the task catalog', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain('To do');
    expect(wrapper.text()).toContain('Dropped');
    expect(wrapper.text()).toContain(
      'CRM.SETTINGS.TASK_STATUSES.CATEGORIES.cancelled'
    );
    expect(wrapper.find('[data-testid="task-catalog"]').exists()).toBe(true);
  });

  it('opens the status drawer for the create-task-status link and clears the query', async () => {
    testState.route.query = { action: 'create-task-status' };
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.find('[data-testid="status-drawer"]').exists()).toBe(true);
    expect(testState.router.replace).toHaveBeenCalledWith({ query: {} });
  });
});
