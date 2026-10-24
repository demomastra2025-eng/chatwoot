import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { nextTick } from 'vue';
import { mount, shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';

import conversationsModule from 'dashboard/store/modules/conversations';
import contactsModule from 'dashboard/store/modules/contacts';
import types from 'dashboard/store/mutation-types';
import { buildCommunicationThreadConversation } from 'dashboard/helper/communicationThreadHelper';
import ConversationCard from './ConversationCard.vue';
import ConversationHeader from './ConversationHeader.vue';

// One person reachable on Telegram and WhatsApp. The list row and the dialog header must show the person's own avatar
// whichever channel an update came from; a channel profile travels apart (channel_profile) and never replaces it.
const PERSON_AVATAR = 'https://cdn.example.com/arman-own.png';
const TELEGRAM_AVATAR = 'https://cdn.example.com/arman-telegram.png';
const WHATSAPP_AVATAR = 'https://cdn.example.com/arman-whatsapp.png';
const THREAD_ID = 7;
const PERSON_ID = 42;

const mocks = vi.hoisted(() => ({ store: null }));

vi.mock('vue-router', () => ({
  useRouter: () => ({
    push: () => {},
    currentRoute: { value: { name: 'communication_threads_dashboard' } },
  }),
  useRoute: () => ({
    name: 'communication_thread_conversation',
    params: { communication_thread_id: 7 },
    query: { status: 'open' },
  }),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: () => {} }));
vi.mock('dashboard/composables/useInbox', () => ({
  useInbox: () => ({ isAWebWidgetInbox: { value: false } }),
}));
vi.mock('dashboard/composables/store', async () => {
  const { computed } = await import('vue');
  return {
    useStore: () => mocks.store,
    useMapGetter: key => computed(() => mocks.store.getters[key]),
  };
});
vi.mock('vuex', async importOriginal => ({
  ...(await importOriginal()),
  useStore: () => mocks.store,
}));
vi.mock('next/avatar/Avatar.vue', () => ({
  default: {
    name: 'Avatar',
    props: ['src', 'name'],
    template: '<div data-test-id="avatar" :data-src="src" />',
  },
}));
vi.mock('../BackButton.vue', () => ({ default: { template: '<div />' } }));
vi.mock('../InboxName.vue', () => ({ default: { template: '<div />' } }));
vi.mock('./MoreActions.vue', () => ({ default: { template: '<div />' } }));

const clone = value => JSON.parse(JSON.stringify(value));

const buildStore = () =>
  createStore({
    state: clone(conversationsModule.state),
    getters: {
      ...conversationsModule.getters,
      getCurrentAccountId: () => 530,
      'inboxes/getInbox': () => id => ({ id, name: `Inbox ${id}` }),
      'inboxes/getInboxes': () => [{ id: 101 }, { id: 202 }],
    },
    actions: conversationsModule.actions,
    mutations: conversationsModule.mutations,
    modules: {
      contacts: {
        namespaced: true,
        state: clone(contactsModule.state),
        getters: contactsModule.getters,
        actions: contactsModule.actions,
        mutations: contactsModule.mutations,
      },
      conversationLabels: {
        namespaced: true,
        actions: { setConversationLabel: () => {} },
      },
    },
  });

const personSender = (extra = {}) => ({
  id: PERSON_ID,
  name: 'Arman',
  thumbnail: PERSON_AVATAR,
  availability_status: 'offline',
  ...extra,
});

// The thread as the list and the show endpoints return it.
const loadedThread = () => ({
  id: THREAD_ID,
  status: 'open',
  updated_at: 1,
  timestamp: 1,
  unread_count: 0,
  inbox_id: null,
  meta: { sender: personSender(), channel: 'CommunicationThread' },
  channels: [
    {
      conversation_id: 11,
      inbox_id: 101,
      channel: 'Channel::TelegramPersonal',
    },
    { conversation_id: 22, inbox_id: 202, channel: 'Channel::WhatsappWeb' },
  ],
  messages: [],
});

const telegramProfile = {
  display_name: 'Arman Telegram',
  avatar_url: TELEGRAM_AVATAR,
  thumbnail: TELEGRAM_AVATAR,
};
const whatsappProfile = {
  display_name: 'Akhan WhatsApp',
  avatar_url: WHATSAPP_AVATAR,
  thumbnail: WHATSAPP_AVATAR,
};

// A thread update as the server sends it for an event of the given channel.
const threadUpdate = ({ conversationId, inboxId, updatedAt }) => ({
  id: THREAD_ID,
  communication_thread_id: THREAD_ID,
  is_communication_thread: true,
  source_event: 'message.created',
  conversation_id: conversationId,
  inbox_id: inboxId,
  updated_at: updatedAt,
  meta: { sender: personSender(), channel: 'CommunicationThread' },
});

// A plain conversation event of one channel: the person keeps their own name and avatar, the profile of the channel
// is carried apart.
const conversationUpdate = ({ id, inboxId, profile, updatedAt }) => ({
  id,
  inbox_id: inboxId,
  updated_at: updatedAt,
  labels: [],
  meta: {
    sender: personSender({ channel_profile: profile }),
    channel_profile: profile,
  },
});

const avatarSrc = wrapper =>
  wrapper.findComponent({ name: 'Avatar' }).props('src');

describe('person avatar across channels', () => {
  let store;

  const selectedThread = () =>
    store.state.allConversations.find(
      chat => chat.is_communication_thread && chat.id === THREAD_ID
    );

  const mountRow = () =>
    shallowMount(ConversationCard, {
      props: {
        chat: selectedThread(),
        activeStatus: 'open',
        communicationThreadMode: true,
      },
      global: {
        stubs: {
          ChannelIcon: true,
          MessageStatus: true,
          MessagePreview: true,
          ConversationContextMenu: true,
          CardLabels: true,
          CardPriorityIcon: true,
          SLACardLabel: true,
          ContextMenu: true,
          VoiceCallStatus: true,
          Checkbox: true,
          FluentIcon: true,
        },
      },
    });

  const mountHeader = () =>
    mount(ConversationHeader, {
      props: { chat: selectedThread() },
      global: {
        stubs: {
          BackButton: true,
          InboxName: true,
          MoreActions: true,
          SLACardLabel: true,
          FluentIcon: true,
        },
      },
    });

  const refresh = async (...wrappers) => {
    await Promise.all(
      wrappers.map(wrapper => wrapper.setProps({ chat: selectedThread() }))
    );
    await nextTick();
  };

  beforeEach(() => {
    store = buildStore();
    mocks.store = store;
    store.commit(types.SET_ALL_CONVERSATION, [
      buildCommunicationThreadConversation(loadedThread()),
    ]);
    store.dispatch('contacts/setContact', personSender());
  });

  afterEach(() => {
    mocks.store = null;
  });

  it('shows the person avatar in the list row and in the dialog header after the thread is loaded', () => {
    expect(avatarSrc(mountRow())).toBe(PERSON_AVATAR);
    expect(avatarSrc(mountHeader())).toBe(PERSON_AVATAR);
  });

  it('keeps the same avatar in the row and the header while updates from other channels arrive', async () => {
    const row = mountRow();
    const header = mountHeader();
    const seen = [];

    const updates = [
      threadUpdate({ conversationId: 11, inboxId: 101, updatedAt: 2 }),
      threadUpdate({ conversationId: 22, inboxId: 202, updatedAt: 3 }),
      threadUpdate({ conversationId: 11, inboxId: 101, updatedAt: 4 }),
      threadUpdate({ conversationId: 22, inboxId: 202, updatedAt: 5 }),
    ];
    await updates.reduce(async (previous, update) => {
      await previous;
      await store.dispatch('updateCommunicationThreadRealtime', update);
      await refresh(row, header);
      seen.push(avatarSrc(row), avatarSrc(header));
    }, Promise.resolve());

    expect(new Set(seen)).toEqual(new Set([PERSON_AVATAR]));
    expect(selectedThread().meta.sender.thumbnail).toBe(PERSON_AVATAR);
  });

  it('does not let the channel profile of a conversation update replace the person avatar', async () => {
    const row = mountRow();
    const header = mountHeader();

    await store.dispatch(
      'updateConversation',
      conversationUpdate({
        id: 11,
        inboxId: 101,
        profile: telegramProfile,
        updatedAt: 2,
      })
    );
    await refresh(row, header);
    expect(avatarSrc(row)).toBe(PERSON_AVATAR);
    expect(avatarSrc(header)).toBe(PERSON_AVATAR);

    await store.dispatch(
      'updateConversation',
      conversationUpdate({
        id: 22,
        inboxId: 202,
        profile: whatsappProfile,
        updatedAt: 3,
      })
    );
    await refresh(row, header);
    expect(avatarSrc(row)).toBe(PERSON_AVATAR);
    expect(avatarSrc(header)).toBe(PERSON_AVATAR);

    // The contact record that the contact panel reads is the person's too.
    const stored = store.getters['contacts/getContact'](PERSON_ID);
    expect(stored.thumbnail).toBe(PERSON_AVATAR);
    expect(stored.name).toBe('Arman');
  });

  it('follows the person when the person avatar itself changes', async () => {
    const row = mountRow();
    const header = mountHeader();
    const newAvatar = 'https://cdn.example.com/arman-new.png';

    await store.dispatch('updateCommunicationThreadRealtime', {
      ...threadUpdate({ conversationId: 22, inboxId: 202, updatedAt: 2 }),
      meta: { sender: personSender({ thumbnail: newAvatar }) },
    });
    await refresh(row, header);

    expect(avatarSrc(row)).toBe(newAvatar);
    expect(avatarSrc(header)).toBe(newAvatar);
  });
});
