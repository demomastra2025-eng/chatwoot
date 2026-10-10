import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import PlaygroundScenarioEditor from './PlaygroundScenarioEditor.vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const scenario = () => ({
  contact: { id: 101, name: 'Mother', phone_number: '+77010000001', identifier: '900101400013', custom_attributes: {} },
  patient: { id: 102, name: 'Son', phone_number: '+77010000002', identifier: '150101500011', custom_attributes: {} },
  appointment: { resource_id: 701, service_id: 801, starts_at: '2026-10-12T11:00:00+05:00', duration_min: 30 },
  resources: [{ id: 701, name: 'Pediatrician', service_ids: [801] }, { id: 702, name: 'Therapist', service_ids: [802] }],
  services: [{ id: 801, name: 'Pediatric visit' }, { id: 802, name: 'Therapy' }],
});

describe('PlaygroundScenarioEditor', () => {
  it('edits the clinical patient without replacing the caller identity or phone', async () => {
    const original = scenario();
    const wrapper = mount(PlaygroundScenarioEditor, { props: { mode: 'trial', modelValue: original } });
    await wrapper.find('[data-test="scenario-patient-name"]').setValue('Updated son');
    const edited = wrapper.emitted('update:modelValue').at(-1)[0];
    expect(edited.patient.name).toBe('Updated son');
    expect(edited.contact).toEqual(original.contact);
    expect(original.patient.name).toBe('Son');
  });

  it('preserves the scenario timezone offset and computes the appointment end', async () => {
    const wrapper = mount(PlaygroundScenarioEditor, { props: { mode: 'trial', modelValue: scenario() } });
    await wrapper.find('input[type="datetime-local"]').setValue('2026-10-12T12:15');
    const edited = wrapper.emitted('update:modelValue').at(-1)[0];
    expect(edited.appointment.starts_at).toBe('2026-10-12T12:15:00+05:00');
    expect(edited.appointment.ends_at).toBe('2026-10-12T07:45:00.000Z');
  });

  it('selects a compatible service when changing the specialist', async () => {
    const wrapper = mount(PlaygroundScenarioEditor, { props: { mode: 'trial', modelValue: scenario() } });
    await wrapper.find('[data-test="scenario-appointment-resource"]').setValue('702');
    expect(wrapper.emitted('update:modelValue').at(-1)[0].appointment).toMatchObject({ resource_id: 702, service_id: 802 });
  });

  it('exposes only the test caller in Live and does not edit a provider identity', async () => {
    const original = scenario();
    original.contact.identifier = 'captain-playground-native-source';
    const wrapper = mount(PlaygroundScenarioEditor, { props: { mode: 'live', modelValue: original } });
    expect(wrapper.find('[data-test="scenario-patient-name"]').exists()).toBe(false);
    expect(wrapper.find('input[type="datetime-local"]').exists()).toBe(false);
    await wrapper.find('[data-test="scenario-contact-iin"]').setValue('900101400013');
    const edited = wrapper.emitted('update:modelValue').at(-1)[0].contact;
    expect(edited.identifier).toBe('captain-playground-native-source');
    expect(edited.custom_attributes.iin).toBe('900101400013');
  });
});
