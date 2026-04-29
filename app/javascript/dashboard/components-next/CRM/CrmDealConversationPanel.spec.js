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

const mountPanel = () =>
  mount(CrmDealConversationPanel, {
    props: {
      conversationDisplayId: 185,
      conversationId: 11963,
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

      if (action === 'setActiveChat') {
        currentChat.value = payload.data;
      }
    });

    useStore.mockReturnValue({ dispatch });
    useMapGetter.mockImplementation(getter => {
      if (getter === 'getConversationById') {
        return ref(conversationId =>
          conversations.value.find(
            conversation => Number(conversation.id) === Number(conversationId)
          )
        );
      }

      if (getter === 'getSelectedChat') {
        return currentChat;
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
});
