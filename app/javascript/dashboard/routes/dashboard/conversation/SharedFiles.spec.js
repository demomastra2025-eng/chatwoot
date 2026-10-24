import { flushPromises, mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import SharedFiles from './SharedFiles.vue';

vi.mock('vue-router', () => ({
  useRoute: () => ({
    fullPath: '/app/accounts/3/conversations/7',
    params: { accountId: '3' },
  }),
}));

const attachmentsOf = count =>
  Array.from({ length: count }, (_, index) => ({
    id: index + 1,
    file_type: 'file',
    data_url: `https://files.test/${index + 1}.pdf`,
    created_at: index + 1,
  }));

const buildStore = (chat, { attachments = [], total = 0 } = {}) => {
  const fetchAllAttachments = vi.fn();
  const store = createStore({
    state: { chat },
    getters: {
      getSelectedChat: state => state.chat,
      getSelectedChatAttachments: () => attachments,
      getSelectedChatAttachmentsLoaded: () => true,
      getSelectedChatAttachmentsTotal: () => total,
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

  it('says how many files are loaded when the list is shorter than the real total', () => {
    const { store } = buildStore(
      { id: 7, is_communication_thread: true },
      { attachments: attachmentsOf(100), total: 340 }
    );

    const wrapper = mountSharedFiles(store);

    expect(
      wrapper.find('[data-test-id="shared-files-partial"]').text()
    ).toMatch(/100.*340|340.*100/);
  });

  it('shows no shortfall note when every attachment is loaded', () => {
    const { store } = buildStore(
      { id: 7, is_communication_thread: true },
      { attachments: attachmentsOf(100), total: 100 }
    );

    const wrapper = mountSharedFiles(store);

    expect(wrapper.find('[data-test-id="shared-files-partial"]').exists()).toBe(
      false
    );
  });

  it('loads the rest again from the shortfall note', async () => {
    const { store, fetchAllAttachments } = buildStore(
      { id: 7, is_communication_thread: true },
      { attachments: attachmentsOf(100), total: 340 }
    );
    const wrapper = mountSharedFiles(store);
    // The first load is still running right after mount and shows a spinner instead of the button.
    await flushPromises();
    fetchAllAttachments.mockClear();

    await wrapper
      .find('[data-test-id="shared-files-partial"] button')
      .trigger('click');
    await flushPromises();

    expect(fetchAllAttachments).toHaveBeenCalledTimes(1);
    expect(fetchAllAttachments).toHaveBeenCalledWith(
      expect.objectContaining({
        conversationId: 7,
        isCommunicationThread: true,
      })
    );
  });

  it('does not request anything without an open chat', () => {
    const { store, fetchAllAttachments } = buildStore({});

    mountSharedFiles(store);

    expect(fetchAllAttachments).not.toHaveBeenCalled();
  });
});
