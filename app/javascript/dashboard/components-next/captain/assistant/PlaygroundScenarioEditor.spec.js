import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import PlaygroundScenarioEditor from './PlaygroundScenarioEditor.vue';
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
const scenario = () => ({
  contact: {
    id: -101,
    name: 'Mother',
    phone_number: '+77010000001',
    custom_attributes: {},
  },
  patients: [{ id: -102, name: 'Son', custom_attributes: {} }],
  deals: [
    {
      id: -501,
      title: 'Deal',
      stage_id: -911,
      pipeline_id: -901,
      custom_attributes: {},
    },
  ],
  appointments: [
    {
      id: -601,
      patient_contact_id: -102,
      resource_id: -701,
      service_id: -801,
      starts_at: '2026-10-12T11:00:00+05:00',
      duration_min: 30,
      status: 'scheduled',
      custom_attributes: {},
    },
  ],
  resources: [
    { id: -701, name: 'Pediatrician', service_ids: [-801], work_rules: [] },
    { id: -702, name: 'Therapist', service_ids: [-802], work_rules: [] },
  ],
  services: [
    { id: -801, name: 'Pediatric visit' },
    { id: -802, name: 'Therapy' },
  ],
  stages: [],
  custom_fields: [],
});

describe('synthetic scenario editor', () => {
  it('edits a patient without mutating the caller or original scenario and can add multiple entity records', async () => {
    const original = scenario();
    const wrapper = mount(PlaygroundScenarioEditor, {
      props: { modelValue: original },
    });
    const inputs = wrapper.findAll('input');
    await inputs[4].setValue('Updated son');
    const edited = wrapper.emitted('update:modelValue').at(-1)[0];
    expect(edited.patients[0].name).toBe('Updated son');
    expect(edited.contact).toEqual(original.contact);
    expect(original.patients[0].name).toBe('Son');
    wrapper.vm.add('patients');
    const added = wrapper.emitted('update:modelValue').at(-1)[0];
    expect(added.patients).toHaveLength(2);
    expect(added.patients[1]).not.toHaveProperty('id');
    expect(added.patients[1].identifier).toBe('');
  });
  it('preserves timezone and materializes an exact end when changing start or duration', async () => {
    const wrapper = mount(PlaygroundScenarioEditor, {
      props: { modelValue: scenario() },
    });
    await wrapper
      .get('input[type="datetime-local"]')
      .setValue('2026-10-12T12:15');
    const edited = wrapper.emitted('update:modelValue').at(-1)[0]
      .appointments[0];
    expect(edited.starts_at).toBe('2026-10-12T12:15:00+05:00');
    expect(edited.ends_at).toBe('2026-10-12T07:45:00.000Z');
  });
  it('exposes only metadata field definitions and keeps custom values inside the draft', async () => {
    const original = scenario();
    original.custom_fields = [
      {
        entity_kind: 'deal',
        key: 'category',
        label: 'Category',
        field_type: 'select',
        options: ['routine', 'urgent'],
        active: true,
      },
    ];
    const wrapper = mount(PlaygroundScenarioEditor, {
      props: { modelValue: original },
    });
    const select = wrapper.get('[data-test="scenario-custom-fields"] select');
    await select.setValue('urgent');
    expect(
      wrapper.emitted('update:modelValue').at(-1)[0].deals[0].custom_attributes
        .category
    ).toBe('urgent');
    expect(original.deals[0].custom_attributes).toEqual({});
  });
});
