import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import CardLabels from './CardLabels.vue';

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ({
    value: [
      { id: 1, title: 'vip', display_title: 'VIP' },
      { id: 2, title: 'warm', display_title: 'Warm' },
      { id: 3, title: 'cold', display_title: 'Cold' },
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
  it('shows every conversation label wrapped without an expand arrow', () => {
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

  it('renders nothing when the conversation has no known labels', () => {
    const wrapper = mount(CardLabels, {
      props: { conversationLabels: ['unknown'] },
      global: {
        components: { WootLabel },
      },
    });

    expect(wrapper.find('.flex-wrap').exists()).toBe(false);
  });
});
