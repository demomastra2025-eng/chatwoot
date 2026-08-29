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
  it('moves the original-size thumb across the symmetric inner track', () => {
    const wrapper = mount(Switch, {
      props: { modelValue: true },
    });

    const thumb = wrapper.find('[data-testid="switch-thumb"]');

    expect(thumb.attributes('class')).toContain(
      'data-[state=checked]:translate-x-4'
    );
    expect(thumb.attributes('class')).not.toContain('shadow-sm');
  });

  it('centers the thumb and keeps the brighter active track', () => {
    const wrapper = mount(Switch);
    const root = wrapper.find('button');

    expect(root.attributes('class')).toContain('h-4');
    expect(root.attributes('class')).toContain('w-8');
    expect(root.attributes('class')).toContain('items-center');
    expect(root.attributes('class')).toContain('p-px');
    expect(root.attributes('class')).toContain(
      'data-[state=checked]:bg-n-blue-9'
    );
    expect(root.attributes('class')).not.toContain(
      'data-[state=checked]:ring-2'
    );
    expect(root.attributes('class')).not.toContain('shadow-sm');
  });
});
