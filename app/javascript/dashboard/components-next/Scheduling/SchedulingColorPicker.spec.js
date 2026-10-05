import { flushPromises, mount } from '@vue/test-utils';
import { afterEach, describe, expect, it } from 'vitest';

import SchedulingColorPicker from './SchedulingColorPicker.vue';

describe('SchedulingColorPicker', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('renders a compact color trigger and emits a palette selection', async () => {
    const wrapper = mount(SchedulingColorPicker, {
      attachTo: document.body,
      props: {
        compact: true,
        modelValue: '#E11D48',
        palette: ['#E11D48', '#2563EB'],
        triggerLabel: 'Stage color',
      },
    });

    const trigger = wrapper.get('button[aria-label="Stage color"]');
    expect(trigger.classes()).toContain('size-5');
    await trigger.trigger('click');
    await flushPromises();

    const blueButton = document.querySelector('button[aria-label="#2563EB"]');
    expect(blueButton).not.toBeNull();
    blueButton.click();
    await flushPromises();

    expect(wrapper.emitted('update:modelValue')).toEqual([['#2563EB']]);
    wrapper.unmount();
  }, 10000);
});
