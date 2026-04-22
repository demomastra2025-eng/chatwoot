import { describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import RuleCard from './RuleCard.vue';

vi.mock('shared/composables/useMessageFormatter', () => ({
  useMessageFormatter: () => ({
    formatMessage: content => content,
  }),
}));

const buttonStub = {
  name: 'Button',
  props: ['icon', 'label'],
  emits: ['click'],
  template:
    '<button :data-icon="icon" :data-label="label" @click="$emit(\'click\')"><slot /></button>',
};

const buildWrapper = props =>
  shallowMount(RuleCard, {
    props: {
      id: 'rule-1',
      content: 'Test content',
      type: 'guardrail',
      group: 'Restrictions',
      typeOptions: [
        { value: 'system', label: 'System' },
        { value: 'response_guideline', label: 'Guideline' },
        { value: 'guardrail', label: 'Guardrail' },
      ],
      typeBadgeMap: {
        guardrail: {
          label: 'Guardrail',
          className: 'guardrail',
          lockedLabel: 'Locked',
          disabledLabel: 'Disabled',
          typeLabel: 'Type',
        },
      },
      ...props,
    },
    global: {
      stubs: {
        Button: buttonStub,
        CardLayout: { template: '<div><slot /></div>' },
        Checkbox: true,
        Editor: true,
        Icon: true,
        Input: true,
        Select: true,
        Switch: true,
      },
    },
  });

describe('RuleCard', () => {
  it('shows the delete action when a rule is deletable even if it is not editable', () => {
    const wrapper = buildWrapper({
      editable: false,
      deletable: true,
    });

    const deleteButton = wrapper.find('button[data-icon="i-lucide-trash"]');
    expect(deleteButton.exists()).toBe(true);
  });
});
