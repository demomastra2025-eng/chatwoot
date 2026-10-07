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

// Tailwind utilities used for the switch geometry, in px (1rem = 16px).
const PX = {
  'h-4': 16,
  'w-7': 28,
  'size-3': 12,
  'top-0.5': 2,
  'left-0.5': 2,
  'data-[state=checked]:translate-x-3': 12,
  'data-[state=unchecked]:translate-x-0': 0,
};

const pick = (classes, prefixes) =>
  classes.filter(name => prefixes.some(prefix => name.startsWith(prefix)));

const px = (classes, prefix) => {
  const matches = pick(classes, [prefix]);
  expect(matches).toHaveLength(1);
  expect(Object.keys(PX)).toContain(matches[0]);
  return PX[matches[0]];
};

const mountSwitch = (options = {}) => {
  const wrapper = mount(Switch, options);
  return {
    wrapper,
    root: wrapper.find('button'),
    thumb: wrapper.find('[data-testid="switch-thumb"]'),
  };
};

describe('Switch', () => {
  it('keeps the upstream Chatwoot size: a 28x16 track and a 12px thumb', () => {
    const { root, thumb } = mountSwitch();

    expect(root.classes()).toEqual(
      expect.arrayContaining(['relative', 'h-4', 'w-7', 'shrink-0', 'p-0'])
    );
    expect(thumb.classes()).toEqual(
      expect.arrayContaining(['absolute', 'top-0.5', 'left-0.5', 'size-3'])
    );
  });

  it('centres the thumb with equal gaps in both states', () => {
    const { root, thumb } = mountSwitch({ props: { modelValue: true } });
    const rootClasses = root.classes();
    const thumbClasses = thumb.classes();

    const trackHeight = px(rootClasses, 'h-');
    const trackWidth = px(rootClasses, 'w-');
    const size = px(thumbClasses, 'size-');
    const top = px(thumbClasses, 'top-');
    const left = px(thumbClasses, 'left-');
    const offTravel = px(thumbClasses, 'data-[state=unchecked]:translate-x-');
    const onTravel = px(thumbClasses, 'data-[state=checked]:translate-x-');

    const bottom = trackHeight - top - size;
    const offLeft = left + offTravel;
    const onRight = trackWidth - (left + onTravel) - size;

    expect({ top, bottom, offLeft, onRight }).toEqual({
      top: 2,
      bottom: 2,
      offLeft: 2,
      onRight: 2,
    });
  });

  it('has no border or flex alignment that could push the thumb off centre', () => {
    const { root } = mountSwitch();
    const classes = root.classes();

    expect(classes).not.toContain('border');
    expect(classes).not.toContain('items-center');
    expect(pick(classes, ['p-0.5', 'px-', 'py-', 'border-'])).toEqual([]);
  });

  it('is blue when on and slate when off, in light and dark themes alike', () => {
    const { root } = mountSwitch();
    const classes = root.classes();

    expect(classes).toContain('bg-n-slate-6');
    expect(classes).toContain('data-[state=checked]:bg-n-blue-9');
    expect(classes.join(' ')).not.toMatch(/brand-solid|violet|dark:/);
  });

  it('dims and blocks the pointer when disabled and keeps a focus ring', () => {
    const { wrapper, root } = mountSwitch({ props: { disabled: true } });

    expect(
      wrapper.findComponent({ name: 'SwitchRoot' }).props('disabled')
    ).toBe(true);
    expect(root.classes()).toEqual(
      expect.arrayContaining([
        'disabled:opacity-60',
        'disabled:cursor-not-allowed',
        'focus-visible:ring-1',
        'focus-visible:ring-n-brand',
      ])
    );
  });

  it('updates the model, emits change and keeps the accessible label', async () => {
    const { wrapper } = mountSwitch({
      props: { modelValue: false },
      attrs: { class: 'mt-0.5' },
    });

    await wrapper
      .findComponent({ name: 'SwitchRoot' })
      .vm.$emit('update:modelValue', true);

    expect(wrapper.emitted('update:modelValue')).toEqual([[true]]);
    expect(wrapper.emitted('change')).toEqual([[true]]);
    expect(wrapper.find('.sr-only').text()).toBe('SWITCH.TOGGLE');
    expect(wrapper.find('button').classes()).toContain('mt-0.5');
  });
});
