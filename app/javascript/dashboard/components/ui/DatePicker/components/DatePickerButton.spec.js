import { shallowMount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import DatePickerButton from './DatePickerButton.vue';

const mountButton = props =>
  shallowMount(DatePickerButton, {
    props: {
      active: true,
      selectedEndDate: new Date(2026, 2, 10),
      selectedStartDate: new Date(2026, 2, 1),
      ...props,
    },
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        Icon: true,
        NextButton: true,
      },
    },
  });

describe('DatePickerButton', () => {
  it('shows a short custom range in compact mode', () => {
    const wrapper = mountButton({
      compact: true,
      ranges: [{ label: 'Custom range', value: 'custom' }],
      selectedRange: 'custom',
    });

    expect(wrapper.get('button').text()).toBe('01.03 – 10.03');
    expect(wrapper.get('button').classes()).toContain('max-w-full');
  });

  it('shows only the preset label in compact mode', () => {
    const wrapper = mountButton({
      compact: true,
      ranges: [{ label: 'Today', value: 'today' }],
      selectedRange: 'today',
    });

    expect(wrapper.get('button').text()).toBe('Today');
  });
});
