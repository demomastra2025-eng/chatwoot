import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { nextTick, reactive } from 'vue';
import { appointmentAutomationDraft } from './appointmentAutomation';
import CrmAppointmentAutomationSettings from './CrmAppointmentAutomationSettings.vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
const SwitchStub = {
  name: 'Switch',
  props: ['modelValue', 'disabled'],
  emits: ['update:modelValue'],
  template: `<button type="button" role="switch" class="switch-stub" :aria-checked="String(Boolean(modelValue))" :disabled="disabled" @click="$emit('update:modelValue', !modelValue)" />`,
};
const pipeline = () => ({
  id: 3,
  name: 'Appointments',
  stages: [
    { id: 4, name: 'Booked', outcome: 'open' },
    { id: 5, name: 'Follow up', outcome: 'open' },
    { id: 7, name: 'Completed', outcome: 'won' },
    {
      id: 6,
      name: 'Lost',
      outcome: 'lost',
      closingReasonOptions: ['Too expensive'],
    },
  ],
  appointmentAutomation: {
    enabled: true,
    rules: [
      { stageId: 4, scope: 'any', conditions: ['provider_confirmed'] },
      { stageId: 5, scope: 'all', conditions: ['cancelled'] },
    ],
  },
});
const mountSettings = (props = {}) => {
  const selectedPipeline = props.pipeline || pipeline();
  return mount(CrmAppointmentAutomationSettings, {
    props: {
      pipeline: selectedPipeline,
      modelValue: reactive(
        appointmentAutomationDraft(selectedPipeline.appointmentAutomation)
      ),
      canManage: true,
      ...props,
    },
    global: {
      mocks: { $t: key => key },
      stubs: {
        Switch: SwitchStub,
        ToggleSwitch: SwitchStub,
        SchedulingSelectField: true,
      },
    },
  });
};

describe('appointment automation settings draft', () => {
  it('maps visit lifecycle events to stages in priority order and automatically enables won attendance', async () => {
    const wrapper = mountSettings();
    const draft = wrapper.props('modelValue');
    expect(draft.auto_create_deals).toBe(false);

    wrapper
      .findComponent('[data-testid="appointment-auto-create-deals"]')
      .vm.$emit('update:modelValue', true);
    await nextTick();
    const calendarSource = wrapper
      .findAll('label')
      .find(label =>
        label.text().includes('CRM.APPOINTMENT_AUTOMATION.CALENDAR_SOURCE')
      );
    expect(calendarSource.find('[role="switch"]').exists()).toBe(true);
    await calendarSource.find('[role="switch"]').trigger('click');
    await nextTick();

    wrapper
      .findComponent('[data-testid="appointment-event-stage-attended"]')
      .vm.$emit('update:modelValue', 7);
    wrapper
      .findComponent('[data-testid="appointment-event-stage-cancelled"]')
      .vm.$emit('update:modelValue', '');
    await nextTick();

    expect(
      wrapper
        .findAll('button')
        .some(button => button.text() === 'CRM.GENERAL.SAVE')
    ).toBe(false);
    expect(draft.auto_create_from_calendar).toBe(true);
    expect(wrapper.vm.buildPayload()).toMatchObject({
      auto_create_deals: true,
      auto_create_from_calendar: true,
      success_mode: 'any_attended',
      rules: [
        {
          stage_id: 7,
          scope: 'any',
          conditions: ['attended'],
          closing_reasons: [],
        },
        {
          stage_id: 4,
          scope: 'any',
          conditions: ['provider_confirmed'],
          closing_reasons: [],
        },
      ],
    });
  });

  it('defaults appointment creation off and preserves explicit legacy source opt-ins under off', () => {
    expect(appointmentAutomationDraft()).toMatchObject({
      auto_create_deals: false,
      auto_create_from_calendar: false,
      auto_create_from_medelement: false,
    });
    expect(
      appointmentAutomationDraft({ autoCreateFromCalendar: true })
        .auto_create_deals
    ).toBe(true);
    expect(
      appointmentAutomationDraft({ auto_create_from_medelement: true })
        .auto_create_deals
    ).toBe(true);
    expect(
      appointmentAutomationDraft({
        autoCreateDeals: false,
        autoCreateFromCalendar: true,
      })
    ).toMatchObject({
      auto_create_deals: false,
      auto_create_from_calendar: true,
    });
    expect(
      appointmentAutomationDraft({
        auto_create_deals: false,
        auto_create_from_medelement: true,
      })
    ).toMatchObject({
      auto_create_deals: false,
      auto_create_from_medelement: true,
    });
  });

  it('offers the MedElement source only for an installed integration and preserves a hidden source setting', async () => {
    const draft = reactive(
      appointmentAutomationDraft({
        auto_create_deals: true,
        auto_create_from_medelement: true,
      })
    );
    const wrapper = mountSettings({ modelValue: draft });
    expect(wrapper.text()).not.toContain(
      'CRM.APPOINTMENT_AUTOMATION.ME_SOURCE'
    );
    expect(wrapper.vm.buildPayload().auto_create_from_medelement).toBe(true);
    await wrapper.setProps({ medelementInstalled: true });
    expect(wrapper.text()).toContain('CRM.APPOINTMENT_AUTOMATION.ME_SOURCE');
    wrapper
      .findComponent('[data-testid="appointment-auto-create-deals"]')
      .vm.$emit('update:modelValue', false);
    await nextTick();
    expect(wrapper.text()).not.toContain(
      'CRM.APPOINTMENT_AUTOMATION.ME_SOURCE'
    );
    expect(draft.auto_create_from_medelement).toBe(true);
  });

  it('uses the replacement parent draft when the selected pipeline changes', async () => {
    const wrapper = mountSettings();
    expect(wrapper.findAll('fieldset')).toHaveLength(5);
    const nextPipeline = { id: 9, name: 'Other', stages: [] };
    await wrapper.setProps({
      pipeline: nextPipeline,
      modelValue: reactive(appointmentAutomationDraft()),
    });
    expect(wrapper.findAll('fieldset')).toHaveLength(0);
    expect(wrapper.vm.buildPayload()).toMatchObject({
      enabled: false,
      auto_create_deals: false,
      rules: [],
    });
  });

  it('accepts new stage draft IDs and only sends closing reasons for Lost', async () => {
    const selected = pipeline();
    selected.stages.push({ id: 'draft-stage-1', name: 'New', outcome: 'open' });
    const draft = reactive(
      appointmentAutomationDraft({
        enabled: true,
        rules: [
          {
            stage_id: 'draft-stage-1',
            conditions: ['provider_confirmed'],
            transition_reason: 'Old reason',
            closing_reasons: ['Too expensive'],
          },
          {
            stage_id: 6,
            conditions: ['cancelled'],
            closing_reasons: ['Too expensive'],
          },
        ],
      })
    );
    const wrapper = mountSettings({ pipeline: selected, modelValue: draft });
    expect(wrapper.text()).not.toContain(
      'CRM.APPOINTMENT_AUTOMATION.TRANSITION_REASON'
    );
    expect(wrapper.vm.buildPayload().rules).toEqual([
      {
        stage_id: 'draft-stage-1',
        scope: 'any',
        conditions: ['provider_confirmed'],
        closing_reasons: [],
      },
      {
        stage_id: 6,
        scope: 'any',
        conditions: ['cancelled'],
        closing_reasons: ['Too expensive'],
      },
    ]);
    draft.rules[0].stage_id = 'missing';
    await nextTick();
    expect(wrapper.vm.buildPayload()).toBe(null);
  });

  it('toggles pause on manual move and disables all controls for view-only or saving', async () => {
    const wrapper = mountSettings({ canManage: false });
    const fields = wrapper.findAllComponents({ name: 'SchedulingSelectField' });
    expect(fields).toHaveLength(5);
    expect(fields[0].props('options')[0]).toEqual({
      value: '',
      label: 'CRM.APPOINTMENT_AUTOMATION.NO_STAGE_CHANGE',
    });
    expect(fields.every(field => field.props('disabled'))).toBe(true);
    expect(
      wrapper
        .findAll('fieldset')
        .every(field => field.attributes('disabled') !== undefined)
    ).toBe(true);

    await wrapper.setProps({ canManage: true, saving: false });
    const pauseSwitch = wrapper.get(
      '[data-testid="appointment-pause-on-manual-move"]'
    );
    expect(pauseSwitch.attributes('aria-checked')).toBe('false');
    await pauseSwitch.trigger('click');
    await nextTick();
    expect(wrapper.vm.buildPayload().manual_stage_change).toBe('pause');

    await wrapper.setProps({ canManage: true, saving: true });
    const switches = wrapper.findAll('[role="switch"]');
    expect(switches.length).toBeGreaterThanOrEqual(3);
    expect(switches.every(control => control.element.disabled)).toBe(true);
  });

  it('renders a pipeline selector when pipelines are provided and emits selection changes', async () => {
    const wrapper = mountSettings({
      pipelines: [
        { id: 10, name: 'Primary funnel' },
        { id: 20, name: 'Repeat visits' },
      ],
      selectedPipelineId: 10,
    });
    const selector = wrapper.findComponent(
      '[data-testid="appointment-automation-pipeline-select"]'
    );
    expect(selector.exists()).toBe(true);
    expect(selector.props('options')).toEqual([
      { value: '10', label: 'Primary funnel' },
      { value: '20', label: 'Repeat visits' },
    ]);
    selector.vm.$emit('update:modelValue', '20');
    await nextTick();
    expect(wrapper.emitted('update:selectedPipelineId')).toEqual([['20']]);
  });

  it('splits legacy multi-condition rules into independent per-event rules so changing scheduled does not mutate confirmed or attended', async () => {
    const draft = reactive(
      appointmentAutomationDraft({
        enabled: true,
        rules: [
          {
            scope: 'any',
            stage_id: 4,
            conditions: ['provider_confirmed', 'patient_confirmed', 'attended'],
          },
          {
            scope: 'any',
            stage_id: 1,
            conditions: ['scheduled'],
          },
        ],
      })
    );
    const wrapper = mountSettings({ modelValue: draft });
    expect(
      wrapper
        .findComponent('[data-testid="appointment-event-stage-scheduled"]')
        .props('modelValue')
    ).toBe(1);
    expect(
      wrapper
        .findComponent(
          '[data-testid="appointment-event-stage-patient_confirmed"]'
        )
        .props('modelValue')
    ).toBe(4);
    expect(
      wrapper
        .findComponent('[data-testid="appointment-event-stage-attended"]')
        .props('modelValue')
    ).toBe(4);

    wrapper
      .findComponent('[data-testid="appointment-event-stage-scheduled"]')
      .vm.$emit('update:modelValue', 2);
    await nextTick();

    expect(
      wrapper
        .findComponent('[data-testid="appointment-event-stage-scheduled"]')
        .props('modelValue')
    ).toBe(2);
    expect(
      wrapper
        .findComponent(
          '[data-testid="appointment-event-stage-patient_confirmed"]'
        )
        .props('modelValue')
    ).toBe(4);
    expect(
      wrapper
        .findComponent('[data-testid="appointment-event-stage-attended"]')
        .props('modelValue')
    ).toBe(4);
  });
});
