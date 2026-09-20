import { describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import CrmTimelineFeed from './CrmTimelineFeed.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

describe('CrmTimelineFeed', () => {
  it('renders a retryable error instead of confirmed-empty history', async () => {
    const wrapper = shallowMount(CrmTimelineFeed, {
      props: {
        collapsible: false,
        emptyMessage: 'CRM.TIMELINE.EMPTY',
        error: 'timeline unavailable',
        items: [],
      },
      global: {
        stubs: {
          SchedulingErrorState: true,
        },
      },
    });

    const errorState = wrapper.findComponent({ name: 'SchedulingErrorState' });
    expect(errorState.exists()).toBe(true);
    expect(errorState.props()).toMatchObject({
      description: 'timeline unavailable',
      title: 'CRM.TIMELINE.LOAD_ERROR',
    });
    expect(wrapper.text()).not.toContain('CRM.TIMELINE.EMPTY');

    errorState.vm.$emit('retry');
    expect(wrapper.emitted('retry')).toHaveLength(1);
  });
});
