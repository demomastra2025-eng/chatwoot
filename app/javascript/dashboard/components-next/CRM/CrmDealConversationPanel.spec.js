import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import { useMapGetter, useStore } from 'dashboard/composables/store';

import CrmDealConversationPanel from './CrmDealConversationPanel.vue';

vi.mock('dashboard/composables/store');
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

const mountPanel = ({
  communicationThreadDisplayId = '',
  communicationThreadId = '',
  conversationId = 11963,
  conversationDisplayId = 185,
} = {}) =>
  mount(CrmDealConversationPanel, {
    props: {
      communicationThreadDisplayId,
      communicationThreadId,
      conversationDisplayId,
      conversationId,
      visible: true,
    },
    global: {
      stubs: {
        Button: true,
        ConversationBox: true,
        SchedulingErrorState: true,
        Spinner: true,
        Transition: false,
      },
    },
  });

describe('CrmDealConversationPanel', () => {
  let currentChat;
  let conversations;
  let dispatch;

  beforeEach(() => {
    currentChat = ref({});
    conversations = ref([]);

    dispatch = vi.fn(async (action, payload) => {
      if (action === 'getConversation' && payload === 185) {
        conversations.value = [
          {
            display_id: 185,
            id: 11963,
            inbox_id: 7,
            messages: [{ id: 1 }],
          },
        ];
      }

      if (action === 'getCommunicationThread' && payload === 41) {
        const thread = {
          communication_thread_id: 41,
          display_id: 41,
          id: 41,
          inbox_id: 7,
          is_communication_thread: true,
          messages: [{ id: 2 }],
        };
        conversations.value = [thread];
        return thread;
      }

      if (action === 'setActiveChat') {
        currentChat.value = payload.data;
      }

      return undefined;
    });

    useStore.mockReturnValue({ dispatch });
    useMapGetter.mockImplementation(getter => {
      if (getter === 'getConversationById') {
        return ref((conversationId, selectedType = null) =>
          conversations.value.find(conversation => {
            const conversationType = conversation.is_communication_thread
              ? 'communication_thread'
              : 'conversation';

            return (
              Number(conversation.id) === Number(conversationId) &&
              (!selectedType || selectedType === conversationType)
            );
          })
        );
      }

      if (getter === 'getSelectedChat') {
        return currentChat;
      }

      if (getter === 'getAllConversations') {
        return conversations;
      }

      return ref(undefined);
    });
  });

  it('loads the linked conversation by display id and activates it by internal id', async () => {
    mountPanel();
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('getConversation', 185);
    expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
      data: expect.objectContaining({
        display_id: 185,
        id: 11963,
      }),
    });
  });

  it('loads by display id when internal id is missing/invalid', async () => {
    mountPanel({ conversationId: '', conversationDisplayId: 185 });
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('getConversation', 185);
    expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
      data: expect.objectContaining({
        display_id: 185,
        id: 11963,
      }),
    });
  });

  it('parses non-digit conversationDisplayId and still opens', async () => {
    mountPanel({ conversationId: '', conversationDisplayId: '#185' });
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('getConversation', 185);
    expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
      data: expect.objectContaining({
        display_id: 185,
        id: 11963,
      }),
    });
  });

  it('loads and activates the linked communication thread when present', async () => {
    mountPanel({
      communicationThreadDisplayId: 41,
      communicationThreadId: 9001,
      conversationDisplayId: '',
      conversationId: '',
    });
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('getCommunicationThread', 41);
    expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
      data: expect.objectContaining({
        display_id: 41,
        id: 41,
        is_communication_thread: true,
      }),
    });
  });
});
