import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { nextTick, reactive } from 'vue';
import { appointmentAutomationDraft } from './appointmentAutomation';
import CrmAppointmentAutomationSettings from './CrmAppointmentAutomationSettings.vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
const pipeline = () => ({
  id: 3,
  name: 'Appointments',
  stages: [
    { id: 4, name: 'Booked', outcome: 'open' },
    { id: 5, name: 'Follow up', outcome: 'open' },
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
        Switch: true,
        SchedulingSelectField: true,
        Button: {
          props: ['label', 'disabled'],
          emits: ['click'],
          template: `<button :disabled="disabled" @click="$emit('click')">{{ label }}</button>`,
        },
      },
    },
  });
};

describe('appointment automation settings draft', () => {
  it('keeps ordered rules and source changes in the parent draft without a child Save', async () => {
    const wrapper = mountSettings();
    const draft = wrapper.props('modelValue');
    expect(draft.auto_create_deals).toBe(false);
    await wrapper
      .findAll('button')
      .find(
        button =>
          button.attributes('aria-label') ===
            'CRM.APPOINTMENT_AUTOMATION.MOVE_UP' &&
          button.attributes('disabled') === undefined
      )
      .trigger('click');
    wrapper
      .findComponent('[data-testid="appointment-auto-create-deals"]')
      .vm.$emit('update:modelValue', true);
    await nextTick();
    wrapper
      .findAllComponents({ name: 'Switch' })[1]
      .vm.$emit('update:modelValue', true);
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
      success_mode: 'manual',
      rules: [
        { stage_id: 5, scope: 'all', conditions: ['cancelled'] },
        { stage_id: 4, scope: 'any', conditions: ['provider_confirmed'] },
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
    expect(wrapper.findAll('fieldset')).toHaveLength(2);
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

  it('offers aggregation and success modes while disabling all controls for view-only or saving', async () => {
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
        .findAll('fieldset')
        .every(field => field.attributes('disabled') !== undefined)
    ).toBe(true);
    await wrapper.setProps({ canManage: true, saving: true });
    expect(
      wrapper
        .findAllComponents({ name: 'Switch' })
        .every(control => control.props('disabled'))
    ).toBe(true);
    expect(
      wrapper.findAll('button').every(button => button.element.disabled)
    ).toBe(true);
  });
});
