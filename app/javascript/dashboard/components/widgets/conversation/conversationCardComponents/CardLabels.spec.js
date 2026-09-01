import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import CardLabels from './CardLabels.vue';

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ({
    value: [
      { id: 1, title: 'vip', display_title: 'VIP' },
      { id: 2, title: 'warm', display_title: 'Warm' },
    ],
  }),
}));

const WootLabel = {
  props: {
    title: {
      type: String,
      default: '',
    },
  },
  template: '<span class="label">{{ title }}</span>',
};

describe('CardLabels', () => {
  it('shows all labels without an expand arrow', () => {
    const wrapper = mount(CardLabels, {
      props: { conversationLabels: ['vip', 'warm'] },
      global: {
        components: { WootLabel },
      },
    });

    expect(wrapper.findAll('.label')).toHaveLength(2);
    expect(wrapper.find('.flex-wrap').exists()).toBe(true);
    expect(wrapper.find('button').exists()).toBe(false);
  });
});
