import { flushPromises, mount } from '@vue/test-utils';
import { reactive } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SchedulingResourcesPage from './SchedulingResourcesPage.vue';

const mocks = vi.hoisted(() => ({ store: null, alert: vi.fn() }));

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: mocks.alert }));
vi.mock('dashboard/api/agents', () => ({
  default: { get: vi.fn().mockResolvedValue({ data: [] }) },
}));
vi.mock('dashboard/stores/scheduling/references', () => ({
  useSchedulingReferencesStore: () => mocks.store,
}));

const stubs = {
  Avatar: true,
  Button: {
    props: ['icon', 'label'],
    emits: ['click'],
    template:
      '<button type="button" :data-icon="icon" @click="$emit(\'click\')">{{ label }}</button>',
  },
  Dialog: true,
  Input: {
    props: ['modelValue', 'label'],
    emits: ['update:modelValue'],
    template:
      '<input :data-label="label" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
  },
  ProviderScheduleCard: true,
  SchedulingColorPicker: true,
  SchedulingDrawer: {
    props: ['modelValue'],
    emits: ['confirm', 'close'],
    template:
      '<div v-if="modelValue"><slot /><button class="drawer-confirm" @click="$emit(\'confirm\')" /></div>',
  },
  SchedulingDurationInput: true,
  SchedulingEmptyState: true,
  SchedulingErrorState: true,
  SchedulingFormFieldGroup: {
    template: '<div><slot name="headerActions" /><slot /></div>',
  },
  SchedulingPageHeader: { template: '<div><slot name="actions" /></div>' },
  SchedulingSelectField: true,
  Spinner: true,
  Switch: true,
  TabBar: true,
  TextArea: true,
};

describe('SchedulingResourcesPage', () => {
  beforeEach(() => {
    mocks.store = reactive({
      loadResources: vi.fn().mockResolvedValue([]),
      resources: [
        {
          active: true,
          customAttributes: { medelement_specialist_code: 'doctor-1' },
          id: 7,
          name: 'Врач',
          specialty: 'Терапевт',
        },
      ],
      saveResource: vi.fn().mockResolvedValue({}),
      ui: { error: null, isLoadingResources: false, isSaving: false },
    });
  });

  it('shows only specialty and saves only specialty for an imported specialist', async () => {
    const wrapper = mount(SchedulingResourcesPage, {
      global: { mocks: { $t: key => key }, stubs },
    });
    await flushPromises();
    expect(wrapper.find('[data-icon="i-lucide-calendar-days"]').exists()).toBe(
      false
    );
    expect(wrapper.find('[data-icon="i-lucide-power"]').exists()).toBe(false);
    expect(wrapper.find('[data-icon="i-lucide-trash-2"]').exists()).toBe(false);

    await wrapper.get('[data-icon="i-lucide-pencil"]').trigger('click');
    expect(wrapper.findAll('input')).toHaveLength(1);
    await wrapper.get('input').setValue('Кардиолог');
    await wrapper.get('.drawer-confirm').trigger('click');
    await flushPromises();

    expect(mocks.store.saveResource).toHaveBeenCalledWith({
      id: 7,
      specialty: 'Кардиолог',
    });
  });
});
