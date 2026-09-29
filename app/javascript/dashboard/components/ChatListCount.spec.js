import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import ChatListCount from './ChatListCount.vue';

const mountComponent = props =>
  mount(ChatListCount, {
    props,
    global: {
      mocks: {
        $t: (key, params) => `${key}:${params?.count}`,
      },
    },
  });

describe('ChatListCount', () => {
  it('renders a single total conversation count line', () => {
    const wrapper = mountComponent({ conversationCount: 42 });

    expect(wrapper.findAll('[data-test-id="conversation-count"]')).toHaveLength(
      1
    );
    expect(wrapper.text()).toBe('CHAT_LIST.TOTAL_COUNT:42');
  });

  it('renders zero instead of hiding the counter for an empty list', () => {
    const wrapper = mountComponent({ conversationCount: 0 });

    expect(wrapper.text()).toBe('CHAT_LIST.TOTAL_COUNT:0');
  });

  it('switches to the search result label while a local search is active', () => {
    const wrapper = mountComponent({
      conversationCount: 3,
      isSearchResult: true,
    });

    expect(wrapper.text()).toBe('CHAT_LIST.LOCAL_SEARCH.RESULT_COUNT:3');
  });

  it('keeps the row height but hides the number while the list is loading', () => {
    const wrapper = mountComponent({
      conversationCount: 12,
      isListLoading: true,
    });

    expect(
      wrapper.find('[data-test-id="conversation-count-row"]').exists()
    ).toBe(true);
    expect(wrapper.find('[data-test-id="conversation-count"]').exists()).toBe(
      false
    );
  });
});
