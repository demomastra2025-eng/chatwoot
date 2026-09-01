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

  it('centers the thumb vertically and keeps the brighter active track', () => {
    const wrapper = mount(Switch);
    const root = wrapper.find('button');
    const thumb = wrapper.find('[data-testid="switch-thumb"]');

    expect(root.attributes('class')).toContain('h-4');
    expect(root.attributes('class')).toContain('w-8');
    expect(root.attributes('class')).toContain('relative');
    expect(thumb.attributes('class')).toContain('absolute');
    expect(thumb.attributes('class')).toContain('top-1/2');
    expect(thumb.attributes('class')).toContain('-translate-y-1/2');
    expect(root.attributes('class')).toContain(
      'data-[state=checked]:bg-n-violet-9'
    );
    expect(root.attributes('class')).not.toContain(
      'data-[state=checked]:ring-2'
    );
    expect(root.attributes('class')).not.toContain('shadow-sm');
  });
});
