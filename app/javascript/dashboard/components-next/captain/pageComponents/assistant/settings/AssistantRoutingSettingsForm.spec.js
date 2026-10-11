import { beforeEach, describe, expect, it, vi } from 'vitest';
import { mount, flushPromises } from '@vue/test-utils';
import { ref } from 'vue';
import AssistantRoutingSettingsForm from './AssistantRoutingSettingsForm.vue';

const mocks = vi.hoisted(() => ({ dispatch: vi.fn() }));
const agents = [
  { id: 1, name: 'Main', active: true, usage_mode: 'external_agent' },
  { id: 2, name: 'Sales', active: true, usage_mode: 'external_agent' },
  { id: 3, name: 'Disabled', active: false, usage_mode: 'external_agent' },
  { id: 4, name: 'Internal', active: true, usage_mode: 'internal_assistant' },
  { id: 5, name: 'Support', active: true, usage_mode: 'external_agent' },
];
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: key =>
    ref(
      key === 'captainAssistants/getRecords' ? agents : { fetchingList: false }
    ),
}));
const mountForm = () =>
  mount(AssistantRoutingSettingsForm, {
    props: {
      assistant: {
        ...agents[0],
        routing_description: 'General requests',
        handoff_agent_ids: [3, 4],
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
  beforeEach(() => mocks.dispatch.mockReset());

  it('offers active external agents and excludes itself, disabled and internal agents', () => {
    const wrapper = mountForm();
    expect(
      wrapper
        .findAll('input[type="checkbox"]')
        .slice(1)
        .map(input => input.element.value)
    ).toEqual(['2', '5']);
  });

  it('keeps edits local until the page builds its save payload', async () => {
    const wrapper = mountForm();
    await wrapper.get('[data-test="active"]').setValue(false);
    await wrapper
      .get('input:not([type="checkbox"])')
      .setValue('  Billing requests  ');
    await wrapper.get('input[value="2"]').setValue(true);
    await wrapper.get('input[value="5"]').setValue(true);
    await flushPromises();
    expect(mocks.dispatch).toHaveBeenCalledWith('captainAssistants/get');
    expect(mocks.dispatch).not.toHaveBeenCalledWith(
      'captainAssistants/update',
      expect.anything()
    );
    expect(wrapper.vm.buildPayload()).toEqual({
      assistant: {
        active: false,
        routing_description: 'Billing requests',
        handoff_agent_ids: [2, 5],
      },
    });
  });
});
