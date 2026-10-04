import { mount } from '@vue/test-utils';
import DsSegmented from '../DsSegmented.vue';

const options = [
  { value: 7, label: '7 days' },
  { value: 14, label: '14 days' },
  { value: 30, label: '30 days' },
];

describe('DsSegmented', () => {
  it('renders one radio per option and marks the selected one', () => {
    const wrapper = mount(DsSegmented, {
      props: { options, modelValue: 14, label: 'Period' },
    });
    const radios = wrapper.findAll('[role="radio"]');

    expect(wrapper.attributes('role')).toBe('radiogroup');
    expect(wrapper.attributes('aria-label')).toBe('Period');
    expect(radios.map(radio => radio.text())).toEqual([
      '7 days',
      '14 days',
      '30 days',
    ]);
    expect(radios[1].attributes('aria-checked')).toBe('true');
    expect(radios[1].classes()).toContain('bg-n-slate-3');
    expect(radios[0].attributes('aria-checked')).toBe('false');
    expect(radios[0].attributes('tabindex')).toBe('-1');
  });

  it('emits the new value on click', async () => {
    const wrapper = mount(DsSegmented, { props: { options, modelValue: 14 } });

    await wrapper.findAll('[role="radio"]')[2].trigger('click');

    expect(wrapper.emitted('update:modelValue')[0]).toEqual([30]);
  });

  it('moves the selection with arrow keys and wraps around', async () => {
    const wrapper = mount(DsSegmented, { props: { options, modelValue: 30 } });
    const radios = wrapper.findAll('[role="radio"]');

    await radios[2].trigger('keydown', { key: 'ArrowRight' });
    await radios[0].trigger('keydown', { key: 'ArrowLeft' });

    expect(wrapper.emitted('update:modelValue')).toEqual([[7], [30]]);
  });

  it('falls back to a translated group label', () => {
    const wrapper = mount(DsSegmented, { props: { options } });
    expect(wrapper.attributes('aria-label')).toBe('Choose an option');
  });
});
