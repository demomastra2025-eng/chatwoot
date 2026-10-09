import { mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import GalleryView from './GalleryView.vue';

vi.mock('vue-router', () => ({
  useRoute: () => ({
    fullPath: '/app/accounts/3/conversations/7',
    params: { accountId: '3' },
  }),
}));

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
    expect(fetchAllAttachments).toHaveBeenCalledWith(
      expect.objectContaining({
        conversationId: 7,
        isCommunicationThread: true,
      })
    );
  });

  it('does not load again when the full list is loaded and has the opened attachment', () => {
    const { store, fetchAllAttachments } = buildStore({ loaded: true });

    const wrapper = mountGallery(store, {
      attachment: image(2),
      allAttachments: [image(1), image(2)],
    });

    expect(fetchAllAttachments).not.toHaveBeenCalled();
    expect(wrapper.find('footer').text()).toBe('2 / 2');
  });

  it('loads the full list when the store only has attachments of new messages', async () => {
    // A patient sent a photo while the chat was open: the store has only that
    // photo. The operator opens an older image from the history.
    const { store, fetchAllAttachments } = buildStore({ loaded: false });
    const wrapper = mountGallery(store, {
      attachment: image(2),
      allAttachments: [image(9)],
    });

    expect(fetchAllAttachments).toHaveBeenCalledTimes(1);
    expect(fetchAllAttachments).toHaveBeenCalledWith(
      expect.objectContaining({
        conversationId: 7,
        isCommunicationThread: false,
      })
    );
    expect(wrapper.find('footer').text()).toBe('0 / 1');

    await wrapper.setProps({
      allAttachments: [image(1), image(2), image(3), image(9)],
    });

    expect(wrapper.find('footer').text()).toBe('2 / 4');
  });

  it('loads the full list when the opened attachment is missing even if a list was fetched', () => {
    const { store, fetchAllAttachments } = buildStore({ loaded: true });

    mountGallery(store, { attachment: image(2), allAttachments: [image(9)] });

    expect(fetchAllAttachments).toHaveBeenCalledTimes(1);
  });

  it('moves to the right position when the full list replaces a partial one', async () => {
    const { store, fetchAllAttachments } = buildStore({ loaded: false });
    const wrapper = mountGallery(store, {
      attachment: image(9),
      allAttachments: [image(9)],
    });

    expect(fetchAllAttachments).toHaveBeenCalledTimes(1);
    expect(wrapper.find('footer').text()).toBe('1 / 1');

    await wrapper.setProps({
      allAttachments: [image(1), image(2), image(9)],
    });

    expect(wrapper.find('footer').text()).toBe('3 / 3');
  });

  it('tells apart several attachments of one message', () => {
    const { store } = buildStore({ loaded: true });
    const wrapper = mountGallery(store, {
      attachment: image(5, 52),
      allAttachments: [image(5, 51), image(5, 52), image(5, 53)],
    });

    expect(wrapper.find('footer').text()).toBe('2 / 3');
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
