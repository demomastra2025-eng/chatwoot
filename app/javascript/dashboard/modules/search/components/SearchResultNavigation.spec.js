import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import SearchResultConversationItem from './SearchResultConversationItem.vue';
import SearchResultMessageItem from './SearchResultMessageItem.vue';
import SearchResultContactItem from './SearchResultContactItem.vue';

vi.mock('dashboard/composables/useInbox', () => ({
  useInbox: () => ({ inbox: { value: null } }),
}));

const RouterLinkStub = {
  name: 'RouterLink',
  props: ['to'],
  template: '<a><slot /></a>',
};

const destination = (component, props) =>
  shallowMount(component, {
    props: { accountId: 1, ...props },
    global: { stubs: { RouterLink: RouterLinkStub } },
  })
    .findComponent(RouterLinkStub)
    .props('to');

describe('global search result navigation', () => {
  it('opens the full thread for a conversation hit and keeps its message anchor', () => {
    const url = destination(SearchResultConversationItem, {
      id: 17,
      inbox: { id: 4 },
      communicationThreadId: 8,
      messageId: 91,
    });
    expect(url).toContain('/app/accounts/1/communication_threads/8?');
    expect(url).toContain('messageId=91');
  });

  it('falls back to the conversation route when no thread is available', () => {
    expect(
      destination(SearchResultConversationItem, {
        id: 17,
        inbox: { id: 4 },
      })
    ).toContain('/conversations/17');
  });

  it('opens a message hit in the thread with its message anchor', () => {
    const url = destination(SearchResultMessageItem, {
      id: 17,
      inboxId: 4,
      communicationThreadId: 8,
      messageId: 91,
    });
    expect(url).toContain('/app/accounts/1/communication_threads/8?');
    expect(url).toContain('messageId=91');
  });

  it('opens the latest thread for a contact hit and retains profile fallback', () => {
    expect(
      destination(SearchResultContactItem, {
        id: 3,
        latestConversation: {
          id: 17,
          inboxId: 4,
          communicationThreadId: 8,
        },
      })
    ).toContain('/app/accounts/1/communication_threads/8?');
    expect(destination(SearchResultContactItem, { id: 3 })).toBe(
      '/app/accounts/1/contacts/3'
    );
  });
});
