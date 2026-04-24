import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

import Switch from './Switch.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('reka-ui', () => ({
  SwitchRoot: {
    name: 'SwitchRoot',
    props: ['modelValue', 'disabled'],
    emits: ['update:modelValue'],
    template: '<button type="button"><slot /></button>',
  },
  SwitchThumb: {
    name: 'SwitchThumb',
    template: '<span data-testid="switch-thumb" />',
  },
}));

describe('Switch', () => {
  it('moves the checked thumb across the full inner track width', () => {
    const wrapper = mount(Switch, {
      props: { modelValue: true },
    });

    const thumb = wrapper.find('[data-testid="switch-thumb"]');

    expect(thumb.attributes('class')).toContain(
      'data-[state=checked]:translate-x-[16px]'
    );
    expect(thumb.attributes('class')).not.toContain(
      'data-[state=checked]:translate-x-[12px]'
    );
  });
});
