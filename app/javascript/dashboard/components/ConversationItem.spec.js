import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import ConversationItem from './ConversationItem.vue';

const ConversationCardStub = {
  name: 'ConversationCard',
  props: {
    selectable: {
      type: Boolean,
      default: false,
    },
  },
  template: '<div />',
};

const mountComponent = props =>
  shallowMount(ConversationItem, {
    props: {
      source: { id: 7, is_communication_thread: true },
      communicationThreadMode: true,
      ...props,
    },
    global: {
      provide: {
        selectConversation: vi.fn(),
        deSelectConversation: vi.fn(),
        assignAgent: vi.fn(),
        assignTeam: vi.fn(),
        assignLabels: vi.fn(),
        removeLabels: vi.fn(),
        updateConversationStatus: vi.fn(),
        toggleContextMenu: vi.fn(),
        markAsUnread: vi.fn(),
        markAsRead: vi.fn(),
        assignPriority: vi.fn(),
        isConversationSelected: vi.fn(() => false),
        deleteConversation: vi.fn(),
      },
      stubs: {
        ConversationCard: ConversationCardStub,
      },
    },
  });

describe('ConversationItem', () => {
  it('keeps communication thread cards selectable for bulk actions', () => {
    const wrapper = mountComponent();

    expect(
      wrapper.findComponent(ConversationCardStub).props('selectable')
    ).toBe(true);
  });
});
