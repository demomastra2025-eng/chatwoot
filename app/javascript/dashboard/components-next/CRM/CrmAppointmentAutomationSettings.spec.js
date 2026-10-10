import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { nextTick, reactive } from 'vue';
import CrmPipelinesAPI from 'dashboard/api/crm/pipelines';
import CrmAppointmentAutomationSettings from './CrmAppointmentAutomationSettings.vue';

const state = vi.hoisted(() => ({ route: null, loadPipelines: vi.fn() }));
vi.mock('vue-router', () => ({ useRoute: () => state.route }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => ({ loadPipelines: state.loadPipelines }),
}));
vi.mock('dashboard/api/crm/pipelines', () => ({
  default: { update: vi.fn() },
}));

const pipeline = () => ({
  id: 3,
  name: 'Appointments',
  stages: [
    { id: 4, name: 'Booked' },
    { id: 5, name: 'Follow up' },
  ],
  appointmentAutomation: {
    enabled: true,
    rules: [
      { stageId: 4, scope: 'any', conditions: ['provider_confirmed'] },
      { stageId: 5, scope: 'all', conditions: ['cancelled'] },
    ],
  },
});
const mountSettings = (props = {}) =>
  mount(CrmAppointmentAutomationSettings, {
    props: { pipeline: pipeline(), canManage: true, ...props },
    global: {
      mocks: { $t: key => key },
      stubs: {
        Input: true,
        Switch: true,
        SchedulingSelectField: true,
        Button: {
          props: ['label', 'disabled'],
          emits: ['click'],
          template:
            '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
        },
      },
    },
  });

describe('appointment automation settings', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.route = reactive({ params: { accountId: '1' } });
    state.loadPipelines.mockResolvedValue([]);
    CrmPipelinesAPI.update.mockResolvedValue({ data: {} });
  });

  it('saves explicit ordered rules and independent source toggles with manual success as default', async () => {
    const wrapper = mountSettings();
    const up = wrapper
      .findAll('button')
      .find(
        button =>
          button.attributes('aria-label') ===
            'CRM.APPOINTMENT_AUTOMATION.MOVE_UP' &&
          button.attributes('disabled') === undefined
      );
    await up.trigger('click');
    const switches = wrapper.findAllComponents({ name: 'Switch' });
    switches[0].vm.$emit('update:modelValue', true);
    const save = wrapper
      .findAll('button')
      .find(button => button.text() === 'CRM.GENERAL.SAVE');
    await save.trigger('click');
    await flushPromises();

    expect(CrmPipelinesAPI.update).toHaveBeenCalledWith(3, {
      appointment_automation: expect.objectContaining({
        enabled: true,
        cardinality: 'request',
        auto_create_from_calendar: true,
        auto_create_from_medelement: false,
        success_mode: 'manual',
        manual_stage_change: 'continue',
        rules: [
          expect.objectContaining({
            stage_id: 5,
            scope: 'all',
            conditions: ['cancelled'],
          }),
          expect.objectContaining({
            stage_id: 4,
            scope: 'any',
            conditions: ['provider_confirmed'],
          }),
        ],
      }),
    });
  });

  it('does not publish an old account mutation result into the new account pipeline references', async () => {
    let release;
    CrmPipelinesAPI.update.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          release = resolve;
        })
    );
    const wrapper = mountSettings();
    const save = wrapper
      .findAll('button')
      .find(button => button.text() === 'CRM.GENERAL.SAVE');
    expect(save.element.disabled).toBe(true);
    wrapper
      .findAllComponents({ name: 'Switch' })[0]
      .vm.$emit('update:modelValue', true);
    await nextTick();
    expect(save.element.disabled).toBe(false);
    await save.trigger('click');
    expect(CrmPipelinesAPI.update).toHaveBeenCalledTimes(1);
    state.route.params.accountId = '2';
    await flushPromises();
    release({ data: { payload: { id: 3 } } });
    await flushPromises();

    expect(state.loadPipelines).not.toHaveBeenCalled();
  });

  it('offers every required aggregation and success mode while respecting view-only permissions', () => {
    const wrapper = mountSettings({ canManage: false });
    const fields = wrapper.findAllComponents({ name: 'SchedulingSelectField' });
    expect(
      fields
        .find(field => field.props('modelValue') === 'manual')
        .props('options')
        .map(option => option.value)
    ).toEqual([
      'manual',
      'any_attended',
      'selected_attended',
      'all_required_attended',
    ]);
    expect(
      fields
        .find(field => field.props('modelValue') === 'any')
        .props('options')
        .map(option => option.value)
    ).toEqual(['any', 'all', 'selected', 'nearest']);
    expect(fields.every(field => field.props('disabled'))).toBe(true);
    expect(
      wrapper
        .findAll('button')
        .some(button => button.text() === 'CRM.GENERAL.SAVE')
    ).toBe(false);
    expect(CrmPipelinesAPI.update).not.toHaveBeenCalled();
  });
});
