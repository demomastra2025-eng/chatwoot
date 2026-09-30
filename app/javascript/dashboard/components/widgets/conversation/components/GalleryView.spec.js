import { mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import GalleryView from './GalleryView.vue';

const image = (messageId, id = messageId) => ({
  id,
  message_id: messageId,
  file_type: 'image',
  data_url: `https://example.test/${id}.png`,
});

const buildStore = ({ chat = { id: 7 }, loaded = false } = {}) => {
  const fetchAllAttachments = vi.fn();
  const store = createStore({
    state: { chat, loaded },
    getters: {
      getCurrentUser: () => ({ id: 1 }),
      getSelectedChat: state => state.chat,
      getSelectedChatAttachmentsLoaded: state => state.loaded,
    },
    actions: {
      fetchAllAttachments: (_, payload) => fetchAllAttachments(payload),
    },
  });

  return { store, fetchAllAttachments };
};

const mountGallery = (store, props) =>
  mount(GalleryView, {
    props: { show: true, ...props },
    global: {
      plugins: [store],
      stubs: {
        TeleportWithDirection: { template: '<div><slot /></div>' },
        WootModal: { template: '<div><slot /></div>' },
        NextButton: { template: '<button type="button" />' },
        Avatar: true,
      },
      directives: { 'dompurify-html': {} },
    },
  });

describe('GalleryView', () => {
  it('loads the open chat attachments when opened from a message without them', () => {
    const { store, fetchAllAttachments } = buildStore({
      chat: { id: 7, is_communication_thread: true },
    });

    mountGallery(store, { attachment: image(2), allAttachments: [] });

    expect(fetchAllAttachments).toHaveBeenCalledTimes(1);
    expect(fetchAllAttachments).toHaveBeenCalledWith({
      conversationId: 7,
      isCommunicationThread: true,
    });
  });

  it('does not load again when the attachments are already known', () => {
    const loadedChat = buildStore({ loaded: true });
    const listedAttachments = buildStore();

    mountGallery(loadedChat.store, {
      attachment: image(2),
      allAttachments: [],
    });
    mountGallery(listedAttachments.store, {
      attachment: image(2),
      allAttachments: [image(1), image(2)],
    });

    expect(loadedChat.fetchAllAttachments).not.toHaveBeenCalled();
    expect(listedAttachments.fetchAllAttachments).not.toHaveBeenCalled();
  });

  it('finds the opened image once the attachments arrive', async () => {
    const { store } = buildStore();
    const wrapper = mountGallery(store, {
      attachment: image(2),
      allAttachments: [],
    });

    expect(wrapper.find('footer').text()).toBe('0 / 0');

    await wrapper.setProps({
      allAttachments: [image(1), image(2), image(3)],
    });

    expect(wrapper.find('footer').text()).toBe('2 / 3');
  });
});
