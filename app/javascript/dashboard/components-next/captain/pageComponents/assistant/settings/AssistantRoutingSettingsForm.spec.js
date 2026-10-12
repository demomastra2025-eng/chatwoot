import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import AssistantRoutingSettingsForm from './AssistantRoutingSettingsForm.vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const mountForm = (assistant = {}) =>
  mount(AssistantRoutingSettingsForm, {
    props: {
      assistant: {
        id: 1,
        name: 'Main',
        active: true,
        usage_mode: 'external_agent',
        routing_description: 'General requests',
        // Legacy stored list: it is no longer shown nor sent.
        handoff_agent_ids: [3, 4],
        ...assistant,
      },
    },
    global: {
      stubs: {
        Input: {
          props: ['modelValue'],
          emits: ['update:modelValue'],
          template:
            '<input :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
        },
        Switch: {
          props: ['modelValue'],
          emits: ['update:modelValue'],
          template:
            '<input data-test="active" type="checkbox" :checked="modelValue" @change="$emit(\'update:modelValue\', $event.target.checked)" />',
        },
      },
    },
  });

describe('agent routing draft', () => {
  it('only offers the active switch and the description peers use for routing', () => {
    const wrapper = mountForm();

    expect(wrapper.findAll('input[type="checkbox"]')).toHaveLength(1);
    expect(wrapper.findAll('input')).toHaveLength(2);
    expect(wrapper.text()).toContain('CAPTAIN.ASSISTANTS.ROUTING.ACTIVE');
    expect(wrapper.text()).not.toContain('CAPTAIN.ASSISTANTS.ROUTING.TARGETS');
  });

  it('keeps edits local until the page builds its save payload', async () => {
    const wrapper = mountForm();
    await wrapper.get('[data-test="active"]').setValue(false);
    await wrapper
      .get('input:not([type="checkbox"])')
      .setValue('  Billing requests  ');

    expect(wrapper.vm.buildPayload()).toEqual({
      assistant: { active: false, routing_description: 'Billing requests' },
    });
  });

  it('never sends the allowed-targets list', () => {
    const payload = mountForm().vm.buildPayload();

    expect(payload.assistant).not.toHaveProperty('handoff_agent_ids');
  });
});
