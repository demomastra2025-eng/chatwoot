import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import ChatListCount from './ChatListCount.vue';

const mountComponent = props =>
  mount(ChatListCount, {
    props: {
      conversationCount: 12,
      isListLoading: false,
      ...props,
    },
    global: {
      mocks: {
        $t: (key, params = {}) =>
          key === 'CHAT_LIST.TOTAL_COUNT' ? `Диалогов: ${params.count}` : key,
      },
    },
  });

describe('ChatListCount', () => {
  it('renders the count in its own fixed-height row', () => {
    const wrapper = mountComponent();
    const row = wrapper.find('[data-testid="conversation-count-row"]');

    expect(row.classes()).toContain('h-5');
    expect(row.classes()).toContain('-mt-1');
    expect(row.classes()).toContain('justify-end');
    expect(row.classes()).toContain('pt-0.5');
    expect(wrapper.find('[data-testid="conversation-count"]').text()).toBe(
      'Диалогов: 12'
    );
  });

  it('keeps the compact row height while the list is loading', () => {
    const wrapper = mountComponent({ isListLoading: true });
    const row = wrapper.find('[data-testid="conversation-count-row"]');

    expect(row.classes()).toContain('h-5');
    expect(wrapper.find('[data-testid="conversation-count"]').exists()).toBe(
      false
    );
  });

  it('renders zero after loading completes', () => {
    const wrapper = mountComponent({ conversationCount: 0 });

    expect(wrapper.find('[data-testid="conversation-count"]').text()).toBe(
      'Диалогов: 0'
    );
  });
});
