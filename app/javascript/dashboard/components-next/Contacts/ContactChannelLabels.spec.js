import { describe, expect, it } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import ContactChannelLabels from './ContactChannelLabels.vue';

const createWrapper = props =>
  shallowMount(ContactChannelLabels, {
    props: {
      contactInboxes: [
        {
          sourceId: 'user@example.com',
          inbox: {
            id: 1,
            name: 'Support Email',
            channelType: 'Channel::Email',
          },
        },
      ],
      ...props,
    },
  });

describe('ContactChannelLabels', () => {
  it('shows a new conversation indicator when no conversation exists yet', () => {
    const wrapper = createWrapper({
      existingConversationInboxIds: [],
    });

    expect(
      wrapper.find('[data-testid="new-conversation-indicator"]').exists()
    ).toBe(true);
  });

  it('hides the new conversation indicator when an inbox already has a conversation', () => {
    const wrapper = createWrapper({
      existingConversationInboxIds: [1],
    });

    expect(
      wrapper.find('[data-testid="new-conversation-indicator"]').exists()
    ).toBe(false);
  });

  it('does not guess before conversations are loaded', () => {
    const wrapper = createWrapper({
      existingConversationInboxIds: null,
    });

    expect(
      wrapper.find('[data-testid="new-conversation-indicator"]').exists()
    ).toBe(false);
  });
});
