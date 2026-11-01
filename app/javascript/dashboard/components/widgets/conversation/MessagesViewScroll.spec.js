import { afterEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import { createStore } from 'vuex';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import MessagesView from './MessagesView.vue';

vi.mock('dashboard/composables/useLabelSuggestions', () => ({
  useLabelSuggestions: () => ({
    captainTasksEnabled: false,
    isLabelSuggestionFeatureEnabled: false,
    getLabelSuggestions: vi.fn(),
  }),
}));

const message = id => ({
  id,
  message_type: 1,
  content: `Message ${id}`,
  created_at: id,
  content_attributes: {},
});

// jsdom has no layout engine. Only the rendered list's geometry and the
// asynchronous network response are simulated; the component, native scroll
// listener, Vuex updates, watchers and scroll methods run unchanged.
const mountConversation = async () => {
  const historyRequest = {};
  const store = createStore({
    state: () => ({
      chat: {
        id: 7,
        inbox_id: 2,
        status: 'open',
        can_reply: true,
        dataFetched: true,
        messages: Array.from({ length: 40 }, (_, index) =>
          message(index + 101)
        ),
        meta: {},
      },
    }),
    getters: {
      getSelectedChat: state => state.chat,
      getCurrentUserID: () => 9,
      getCurrentAccountId: () => 1,
      getAllMessagesLoaded: () => false,
      'inboxes/getInbox': () => () => ({
        id: 2,
        channel_type: 'Channel::WebWidget',
      }),
      'inboxes/getInstagramInboxByInstagramId': () => () => null,
      'conversationTypingStatus/getUserList': () => () => [],
    },
    actions: {
      fetchPreviousMessages: ({ state }, payload) =>
        new Promise(resolve => {
          historyRequest.payload = payload;
          historyRequest.resolve = () => {
            state.chat = {
              ...state.chat,
              messages: [
                ...Array.from({ length: 20 }, (_, index) =>
                  message(index + 81)
                ),
                ...state.chat.messages,
              ],
            };
            resolve();
          };
        }),
      markMessagesRead: vi.fn(),
    },
  });
  const wrapper = mount(MessagesView, {
    shallow: true,
    attachTo: document.body,
    global: {
      plugins: [store],
      mocks: { $route: { query: {} } },
      stubs: {
        MessageList: {
          props: ['messages'],
          template:
            '<ul><slot name="beforeAll" /><li v-for="item in messages" :id="\'message\' + item.id" :key="item.id">{{ item.content }}</li><slot name="after" /></ul>',
        },
      },
    },
  });
  const panel = wrapper.get('.conversation-panel').element;
  Object.defineProperties(panel, {
    clientHeight: { configurable: true, value: 500 },
    scrollHeight: {
      configurable: true,
      get: () => panel.querySelectorAll('[id^="message"]').length * 50,
    },
  });
  await flushPromises();
  wrapper.vm.scrollToBottom();
  panel.dispatchEvent(new Event('scroll'));
  await nextTick();
  return { wrapper, panel, store, historyRequest };
};

const userScroll = async (panel, top) => {
  panel.scrollTop = top;
  panel.dispatchEvent(new Event('scroll'));
  await nextTick();
};

const loadOlderHistory = async context => {
  const { wrapper, panel, historyRequest } = context;
  await userScroll(panel, 40);
  expect(historyRequest.payload).toEqual({ conversationId: 7, before: 101 });
  historyRequest.resolve();
  await flushPromises();
  expect(panel.scrollTop).toBe(1040);
  panel.dispatchEvent(new Event('scroll'));
  await nextTick();
  return wrapper;
};

describe('MessagesView history reading scroll state', () => {
  let context;

  afterEach(() => {
    context?.wrapper.unmount();
    document.body.innerHTML = '';
  });

  it('keeps the loaded history anchor through native scroll and realtime updates', async () => {
    context = await mountConversation();
    const { panel, store, wrapper } = context;
    await loadOlderHistory(context);

    // A receipt updates the selected chat without changing its identity.
    store.state.chat = { ...store.state.chat, unread_count: 1 };
    emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE);
    await flushPromises();
    expect(panel.scrollTop).toBe(1040);
    expect(wrapper.vm.hasUserScrolled).toBe(true);
    expect(wrapper.vm.hasUserScrolledUp).toBe(true);

    // A newly received message changes both the list and the scroll height.
    store.state.chat = {
      ...store.state.chat,
      messages: [...store.state.chat.messages, message(141)],
    };
    await flushPromises();
    expect(panel.scrollTop).toBe(1040);

    panel.dispatchEvent(new Event('load', { bubbles: false }));
    await flushPromises();
    expect(panel.scrollTop).toBe(1040);
  });

  it('resumes following messages after the user intentionally returns to the bottom', async () => {
    context = await mountConversation();
    const { panel, store, wrapper } = context;
    await loadOlderHistory(context);
    await userScroll(panel, panel.scrollHeight - panel.clientHeight);
    expect(wrapper.vm.hasUserScrolled).toBe(false);

    store.state.chat = {
      ...store.state.chat,
      messages: [...store.state.chat.messages, message(141)],
    };
    await flushPromises();
    expect(panel.scrollTop).toBe(2550);
  });

  it('follows a forced jump immediately and on subsequent message updates', async () => {
    context = await mountConversation();
    const { panel, store, wrapper } = context;
    await loadOlderHistory(context);
    // Simulate a second upward user gesture so the forced jump must clear it.
    await userScroll(panel, 700);
    emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE, { force: true });
    await flushPromises();
    expect(panel.scrollTop).toBe(2500);
    expect(wrapper.vm.hasUserScrolled).toBe(false);

    // A fast update can arrive before the browser's eventual scroll event.
    store.state.chat = {
      ...store.state.chat,
      messages: [...store.state.chat.messages, message(141)],
    };
    await flushPromises();
    expect(panel.scrollTop).toBe(2550);
  });

  it('opens a different conversation at its newest message after reading history', async () => {
    context = await mountConversation();
    const { panel, store, wrapper } = context;
    await loadOlderHistory(context);
    await userScroll(panel, 700);
    store.state.chat = {
      ...store.state.chat,
      id: 8,
      messages: Array.from({ length: 30 }, (_, index) => message(index + 201)),
    };
    emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE);
    await flushPromises();
    expect(wrapper.vm.hasUserScrolled).toBe(false);
    expect(wrapper.vm.hasUserScrolledUp).toBe(false);
    expect(panel.scrollTop).toBe(1000);
  });
});
