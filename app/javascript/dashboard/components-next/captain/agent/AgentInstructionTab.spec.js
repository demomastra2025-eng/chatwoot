import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import AgentInstructionTab from './AgentInstructionTab.vue';

vi.mock('dashboard/components-next/Editor/Editor.vue', () => ({
  default: {
    name: 'Editor',
    props: ['modelValue'],
    emits: ['update:modelValue'],
    template: '<div />',
  },
}));
vi.mock('./AgentToolChips.vue', () => ({ default: { template: '<div />' } }));
vi.mock('./AgentFollowUpsSummary.vue', () => ({
  default: { template: '<div />' },
}));

const draft = {
  instruction: 'Synthetic instructions',
  model: 'internal-model-fixture',
  temperature: 0.2,
  thinkingEffort: 'high',
};
describe('AgentInstructionTab', () => {
  it.each([true, false])(
    'hides technical models for canEdit=%s while preserving the server draft',
    async canEdit => {
      const wrapper = shallowMount(AgentInstructionTab, {
        props: { canEdit, assistant: { id: 1, config: {} }, draft },
      });
      expect(wrapper.text()).not.toContain('internal-model-fixture');
      expect(wrapper.find('agent-model-block-stub').exists()).toBe(false);
      expect(wrapper.emitted('update:draft')).toBeUndefined();
      if (canEdit) {
        wrapper
          .getComponent({ name: 'Editor' })
          .vm.$emit('update:modelValue', 'Updated instructions');
        expect(wrapper.emitted('update:draft')).toEqual([
          [{ ...draft, instruction: 'Updated instructions' }],
        ]);
      } else {
        expect(
          wrapper.get('[data-test="agent-instruction-readonly"]').text()
        ).toBe('Synthetic instructions');
      }
    }
  );
});
