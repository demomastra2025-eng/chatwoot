import { describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import CrmTimelineFeed from './CrmTimelineFeed.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

describe('CrmTimelineFeed', () => {
  it('uses conversation navigation only for typed conversation entries', () => {
    const wrapper = shallowMount(CrmTimelineFeed, {
      props: {
        accountId: 74,
        collapsible: false,
        items: [
          {
            itemType: 'conversation',
            occurredAt: '2026-11-03T00:00:00Z',
            payload: { id: 98765, displayId: 12, status: 'resolved' },
          },
          {
            itemType: 'comment',
            occurredAt: '2026-11-02T00:00:00Z',
            payload: { id: 22, body: 'Conversation #99' },
          },
        ],
      },
    });
    const links = wrapper.findAllComponents({ name: 'CrmConversationLink' });
    expect(links).toHaveLength(1);
    expect(links[0].props()).toMatchObject({
      accountId: 74,
      displayId: 12,
    });
    expect(wrapper.text()).toContain('Conversation #99');
  });

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
