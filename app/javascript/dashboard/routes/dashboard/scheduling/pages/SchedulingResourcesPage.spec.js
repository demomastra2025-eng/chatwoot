import { flushPromises, mount } from '@vue/test-utils';
import { reactive } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import ResourceServiceStatsList from './ResourceServiceStatsList.vue';
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
  ResourceServiceStatsList: true,
  SchedulingColorPicker: true,
  SchedulingDateTimeField: true,
  SchedulingDrawer: {
    props: ['modelValue', 'disableConfirm'],
    emits: ['confirm', 'close'],
    template:
      '<div v-if="modelValue"><slot /><button type="button" class="drawer-close" @click="$emit(\'close\')" /><button type="button" class="drawer-confirm" :disabled="disableConfirm" @click="$emit(\'confirm\')" /></div>',
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
  Switch: {
    props: ['modelValue'],
    emits: ['update:modelValue'],
    template:
      '<button role="switch" :aria-checked="modelValue" @click="$emit(\'update:modelValue\', !modelValue)" />',
  },
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

  it('lists the services found in the visit history for an imported specialist only', async () => {
    const wrapper = mount(SchedulingResourcesPage, {
      global: { mocks: { $t: key => key }, stubs },
    });
    await flushPromises();
    expect(wrapper.find('resource-service-stats-list-stub').exists()).toBe(
      false
    );

    await wrapper.get('[data-icon="i-lucide-pencil"]').trigger('click');
    expect(
      wrapper.findComponent(ResourceServiceStatsList).props('resourceId')
    ).toBe(7);

    mocks.store.resources = [
      { active: true, customAttributes: {}, id: 12, name: 'Алия' },
    ];
    const localWrapper = mount(SchedulingResourcesPage, {
      global: { mocks: { $t: key => key }, stubs },
    });
    await flushPromises();
    await localWrapper.get('[data-icon="i-lucide-pencil"]').trigger('click');
    expect(localWrapper.find('resource-service-stats-list-stub').exists()).toBe(
      false
    );
  });

  it('opens schedule drawer with workday overrides and time-offs for a local specialist', async () => {
    mocks.store.resources = [
      {
        active: true,
        customAttributes: {},
        id: 12,
        inheritWorkingHoursFromAccount: true,
        name: 'Алия',
        specialty: 'Терапевт',
      },
    ];
    mocks.store.loadExceptions = vi.fn().mockResolvedValue();
    mocks.store.workdayOverrides = [
      {
        breakEndMinute: null,
        breakStartMinute: null,
        date: '2026-10-20',
        endMinute: 960,
        id: 55,
        resourceId: 12,
        startMinute: 540,
      },
    ];
    mocks.store.timeOffs = [];

    const wrapper = mount(SchedulingResourcesPage, {
      global: { mocks: { $t: key => key }, stubs },
    });
    await flushPromises();

    const scheduleButton = wrapper.find('[data-icon="i-lucide-calendar-days"]');
    expect(scheduleButton.exists()).toBe(true);

    await scheduleButton.trigger('click');
    await flushPromises();

    expect(mocks.store.loadExceptions).toHaveBeenCalled();
    expect(
      wrapper.find('[data-testid="resource-workday-overrides-tab"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-testid="resource-workday-override-row"]').text()
    ).toContain('2026-10-20');
  });

  it('hides resources archived with snake_case deleted_from_scheduling after page reload', async () => {
    mocks.store.resources = [
      {
        active: false,
        customAttributes: { deleted_from_scheduling: true },
        id: 43,
        name: 'Асет',
        specialty: 'Хирург',
      },
      {
        active: true,
        customAttributes: {},
        id: 44,
        name: 'Дина',
        specialty: 'Терапевт',
      },
    ];

    const wrapper = mount(SchedulingResourcesPage, {
      global: { mocks: { $t: key => key }, stubs },
    });
    await flushPromises();

    expect(wrapper.text()).not.toContain('Асет');
    expect(wrapper.text()).toContain('Дина');
  });

  const mountLocalResource = async ({
    inherited = false,
    workRules = [],
  } = {}) => {
    mocks.store.resources = [
      {
        active: false,
        customAttributes: {},
        id: 12,
        name: 'Specialist',
        inheritWorkingHoursFromAccount: inherited,
        slotDurationMin: 30,
      },
    ];
    mocks.store.loadExceptions = vi.fn().mockResolvedValue();
    mocks.store.loadWorkRules = vi.fn().mockResolvedValue(workRules);
    mocks.store.loadBreakRules = vi.fn().mockResolvedValue([
      {
        weekday: 1,
        startMinute: 780,
        endMinute: 810,
        title: 'Lunch',
        active: true,
      },
      {
        weekday: 1,
        startMinute: 900,
        endMinute: 915,
        title: 'Rest',
        active: true,
      },
    ]);
    mocks.store.workdayOverrides = [];
    mocks.store.timeOffs = [];
    const wrapper = mount(SchedulingResourcesPage, {
      global: { mocks: { $t: key => key }, stubs },
    });
    await flushPromises();
    return wrapper;
  };

  it('edits profile fields without a second active control or schedule settings', async () => {
    const wrapper = await mountLocalResource();
    await wrapper.get('[data-icon="i-lucide-pencil"]').trigger('click');
    expect(wrapper.findAll('[role="switch"]')).toHaveLength(0);
    await wrapper.get('.drawer-confirm').trigger('click');
    await flushPromises();
    const [payload] = mocks.store.saveResource.mock.calls[0];
    expect(payload).not.toHaveProperty('active');
    expect(payload).not.toHaveProperty('inherit_working_hours_from_account');
    expect(mocks.store.resources[0].active).toBe(false);
  });

  it('keeps inheritance changes in the schedule draft until Save', async () => {
    const wrapper = await mountLocalResource({ inherited: true });
    await wrapper.get('[data-icon="i-lucide-calendar-days"]').trigger('click');
    await flushPromises();
    const inheritance = wrapper.get(
      '[aria-label="SCHEDULING.RESOURCES.INHERIT_HOURS"]'
    );
    await inheritance.trigger('click');
    expect(mocks.store.saveResource).not.toHaveBeenCalled();
    expect(mocks.store.resources[0].inheritWorkingHoursFromAccount).toBe(true);
    expect(
      wrapper.findAll('[data-testid="resource-work-rule-row"]')
    ).toHaveLength(7);
  });

  it('saves inheritance, personal weekdays and all breaks through one atomic request', async () => {
    const wrapper = await mountLocalResource({
      inherited: true,
      workRules: [
        { weekday: 1, startMinute: 600, endMinute: 1020, active: true },
      ],
    });
    await wrapper.get('[data-icon="i-lucide-calendar-days"]').trigger('click');
    await flushPromises();
    await wrapper
      .get('[aria-label="SCHEDULING.RESOURCES.INHERIT_HOURS"]')
      .trigger('click');
    await wrapper.get('.drawer-confirm').trigger('click');
    await flushPromises();
    expect(mocks.store.saveResource).toHaveBeenCalledTimes(1);
    const [payload] = mocks.store.saveResource.mock.calls[0];
    expect(payload.id).toBe(12);
    expect(payload.inherit_working_hours_from_account).toBe(false);
    expect(payload.work_rules).toHaveLength(7);
    expect(payload.work_rules.find(rule => rule.weekday === 1)).toEqual({
      weekday: 1,
      start_minute: 600,
      end_minute: 1020,
      active: true,
    });
    expect(payload.break_rules.filter(rule => rule.weekday === 1)).toEqual([
      {
        weekday: 1,
        start_minute: 780,
        end_minute: 810,
        title: 'Lunch',
        active: true,
      },
      {
        weekday: 1,
        start_minute: 900,
        end_minute: 915,
        title: 'Rest',
        active: true,
      },
    ]);
  });

  it('has one working row per weekday and cannot create another Monday', async () => {
    const wrapper = await mountLocalResource();
    await wrapper.get('[data-icon="i-lucide-calendar-days"]').trigger('click');
    await flushPromises();
    const rows = wrapper.findAll('[data-testid="resource-work-rule-row"]');
    expect(rows).toHaveLength(7);
    expect(new Set(rows.map(row => row.attributes('data-weekday'))).size).toBe(
      7
    );
    expect(
      rows.some(row => row.find('[data-icon="i-lucide-plus"]').exists())
    ).toBe(false);
  });

  it('keeps failed saves open with the same draft and supports retry', async () => {
    const wrapper = await mountLocalResource();
    mocks.store.saveResource.mockRejectedValueOnce(new Error('Request failed'));
    await wrapper.get('[data-icon="i-lucide-calendar-days"]').trigger('click');
    await flushPromises();
    await wrapper.get('.drawer-confirm').trigger('click');
    await flushPromises();
    const firstPayload = mocks.store.saveResource.mock.calls[0][0];
    expect(
      wrapper.findAll('[data-testid="resource-work-rule-row"]')
    ).toHaveLength(7);
    await wrapper.get('.drawer-confirm').trigger('click');
    await flushPromises();
    expect(mocks.store.saveResource.mock.calls[1][0]).toEqual(firstPayload);
    expect(wrapper.find('.drawer-confirm').exists()).toBe(false);
  });

  it('saves inheritance without clearing hidden personal rule sets from the client', async () => {
    const wrapper = await mountLocalResource();
    await wrapper.get('[data-icon="i-lucide-calendar-days"]').trigger('click');
    await flushPromises();
    await wrapper
      .get('[aria-label="SCHEDULING.RESOURCES.INHERIT_HOURS"]')
      .trigger('click');
    await wrapper.get('.drawer-confirm').trigger('click');
    await flushPromises();
    expect(mocks.store.saveResource).toHaveBeenCalledWith({
      id: 12,
      inherit_working_hours_from_account: true,
    });
  });

  it('cannot save an unloaded schedule after a load failure', async () => {
    const wrapper = await mountLocalResource();
    mocks.store.loadWorkRules.mockRejectedValueOnce(new Error('Load failed'));
    await wrapper.get('[data-icon="i-lucide-calendar-days"]').trigger('click');
    await flushPromises();
    expect(wrapper.get('.drawer-confirm').attributes('disabled')).toBeDefined();
    expect(mocks.store.saveResource).not.toHaveBeenCalled();
  });

  it('blocks duplicate submits and does not close a reopened draft after an older save finishes', async () => {
    const wrapper = await mountLocalResource();
    let finishSave;
    mocks.store.saveResource.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          finishSave = resolve;
        })
    );
    await wrapper.get('[data-icon="i-lucide-calendar-days"]').trigger('click');
    await flushPromises();
    await wrapper.get('.drawer-confirm').trigger('click');
    await wrapper.get('.drawer-confirm').trigger('click');
    expect(mocks.store.saveResource).toHaveBeenCalledTimes(1);
    await wrapper.get('.drawer-close').trigger('click');
    await flushPromises();
    await wrapper.get('[data-icon="i-lucide-calendar-days"]').trigger('click');
    await flushPromises();
    finishSave({ id: 12 });
    await flushPromises();
    expect(
      wrapper.findAll('[data-testid="resource-work-rule-row"]')
    ).toHaveLength(7);
  });

  it('preserves multiple breaks and still allows another break without adding a working day', async () => {
    const wrapper = await mountLocalResource();
    await wrapper.get('[data-icon="i-lucide-calendar-days"]').trigger('click');
    await flushPromises();
    wrapper
      .findComponent({ name: 'TabBar' })
      .vm.$emit('tabChanged', { value: 'break' });
    await flushPromises();
    const selector =
      '[data-testid="resource-break-rule-row"][data-weekday="1"]';
    expect(wrapper.findAll(selector)).toHaveLength(2);
    await wrapper
      .findAll(selector)[0]
      .get('[data-icon="i-lucide-plus"]')
      .trigger('click');
    expect(wrapper.findAll(selector)).toHaveLength(3);
    expect(
      wrapper.findAll('[data-testid="resource-work-rule-row"]')
    ).toHaveLength(0);
  });

  it('shows legacy duplicate days and blocks saving until the extra interval is removed', async () => {
    const wrapper = await mountLocalResource({
      workRules: [
        { weekday: 1, startMinute: 540, endMinute: 720, active: true },
        { weekday: 1, startMinute: 780, endMinute: 1020, active: true },
      ],
    });
    await wrapper.get('[data-icon="i-lucide-calendar-days"]').trigger('click');
    await flushPromises();
    expect(
      wrapper.findAll(
        '[data-testid="resource-work-rule-row"][data-weekday="1"]'
      )
    ).toHaveLength(2);
    expect(wrapper.text()).toContain('SCHEDULING.RESOURCES.DUPLICATE_WORKDAYS');
    expect(wrapper.get('.drawer-confirm').attributes('disabled')).toBeDefined();
    const firstMonday = wrapper.findAll(
      '[data-testid="resource-work-rule-row"][data-weekday="1"]'
    )[0];
    await firstMonday.get('[data-icon="i-lucide-trash-2"]').trigger('click');
    expect(
      wrapper.findAll(
        '[data-testid="resource-work-rule-row"][data-weekday="1"]'
      )
    ).toHaveLength(1);
    expect(
      wrapper.get('.drawer-confirm').attributes('disabled')
    ).toBeUndefined();
    await wrapper.get('.drawer-confirm').trigger('click');
    await flushPromises();
    expect(
      mocks.store.saveResource.mock.calls[0][0].work_rules.find(
        rule => rule.weekday === 1
      )
    ).toMatchObject({ start_minute: 780, end_minute: 1020 });
  });
});
