import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import SchedulingViewSwitcher from './SchedulingViewSwitcher.vue';

const views = [
  { icon: 'i-lucide-columns-3', label: 'Board', value: 'board' },
  { icon: 'i-lucide-list', label: 'List', value: 'list' },
];

describe('SchedulingViewSwitcher', () => {
  it('renders accessible icon-only controls and emits the selected view', async () => {
    const wrapper = mount(SchedulingViewSwitcher, {
      props: {
        iconOnly: true,
        modelValue: 'board',
        views,
      },
    });

    const boardButton = wrapper.get('button[aria-label="Board"]');
    const listButton = wrapper.get('button[aria-label="List"]');

    expect(boardButton.attributes('aria-pressed')).toBe('true');
    expect(listButton.attributes('aria-pressed')).toBe('false');
    expect(wrapper.text()).not.toContain('Board');
    expect(wrapper.text()).not.toContain('List');

    await listButton.trigger('click');

    expect(wrapper.emitted('update:modelValue')).toEqual([['list']]);
  });

  it('preserves text labels by default', () => {
    const wrapper = mount(SchedulingViewSwitcher, {
      props: {
        modelValue: 'board',
        views,
      },
    });

    expect(wrapper.text()).toContain('Board');
    expect(wrapper.text()).toContain('List');
  });
});
