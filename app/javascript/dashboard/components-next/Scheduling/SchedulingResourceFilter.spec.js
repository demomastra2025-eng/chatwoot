import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import SchedulingResourceFilter from './SchedulingResourceFilter.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const global = {
  stubs: {
    Avatar: {
      template: '<div />',
    },
    Button: {
      emits: ['click'],
      template: '<button @click="$emit(\'click\')"><slot /></button>',
    },
    Checkbox: {
      template: '<div data-testid="resource-checkbox" />',
    },
    Input: {
      inheritAttrs: false,
      template: '<input />',
    },
    OnClickOutside: {
      template: '<div><slot /></div>',
    },
    Teleport: true,
  },
};

describe('SchedulingResourceFilter', () => {
  it('keeps the checkbox fixed when a specialist name is long', async () => {
    const wrapper = mount(SchedulingResourceFilter, {
      global,
      props: {
        modelValue: [1],
        resources: [
          {
            id: 1,
            name: 'QA-MEDELEMENT-1786587187 Specialist',
            specialty: 'Cardiology QA',
          },
        ],
      },
    });

    await wrapper.get('button').trigger('click');

    expect(
      wrapper.get('[data-testid="resource-checkbox"]').classes()
    ).toContain('shrink-0');
  });
});
