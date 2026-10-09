import { flushPromises, mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import SharedFiles from './SharedFiles.vue';

vi.mock('vue-router', () => ({
  useRoute: () => ({
    fullPath: '/app/accounts/3/conversations/7',
    params: { accountId: '3' },
  }),
}));

const buildStore = chat => {
  const fetchAllAttachments = vi.fn();
  const store = createStore({
    state: { chat },
    getters: {
      getSelectedChat: state => state.chat,
      getSelectedChatAttachments: () => [],
      getSelectedChatAttachmentsLoaded: () => true,
    },
    mutations: {
      setChat(state, nextChat) {
        state.chat = nextChat;
      },
    },
    actions: {
      fetchAllAttachments: (_, payload) => fetchAllAttachments(payload),
    },
  });

  return { store, fetchAllAttachments };
};

const mountSharedFiles = store =>
  mount(SharedFiles, {
    global: {
      plugins: [store],
      stubs: {
        GalleryView: true,
        Icon: true,
        FileIcon: true,
        NextButton: true,
        Spinner: true,
      },
    },
  });

describe('SharedFiles', () => {
  it('loads the attachments of the open thread when the panel opens', () => {
    const { store, fetchAllAttachments } = buildStore({
      id: 7,
      is_communication_thread: true,
    });

    mountSharedFiles(store);

    expect(fetchAllAttachments).toHaveBeenCalledTimes(1);
    expect(fetchAllAttachments).toHaveBeenCalledWith(
      expect.objectContaining({
        conversationId: 7,
        isCommunicationThread: true,
      })
    );
  });

  it('reloads when switching between a thread and a conversation with the same id', async () => {
    const { store, fetchAllAttachments } = buildStore({
      id: 7,
      is_communication_thread: true,
    });
    mountSharedFiles(store);

    store.commit('setChat', { id: 7 });
    await flushPromises();

    expect(fetchAllAttachments).toHaveBeenCalledTimes(2);
    expect(fetchAllAttachments).toHaveBeenLastCalledWith(
      expect.objectContaining({
        conversationId: 7,
        isCommunicationThread: false,
      })
    );
  });

  it('does not reload for updates of the same chat', async () => {
    const { store, fetchAllAttachments } = buildStore({ id: 7 });
    mountSharedFiles(store);

    store.commit('setChat', { id: 7, unread_count: 3 });
    await flushPromises();

    expect(fetchAllAttachments).toHaveBeenCalledTimes(1);
  });

  it('does not request anything without an open chat', () => {
    const { store, fetchAllAttachments } = buildStore({});

    mountSharedFiles(store);

    expect(fetchAllAttachments).not.toHaveBeenCalled();
  });
});
