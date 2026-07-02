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
  canManage = true,
  communicationThreadDisplayId = '',
  communicationThreadId = '',
  contactableInboxes = [],
  contacts = [],
  conversationId = 11963,
  conversationDisplayId = 185,
  selectedContactId = '',
} = {}) =>
  mount(CrmDealConversationPanel, {
    props: {
      canManage,
      communicationThreadDisplayId,
      communicationThreadId,
      contactableInboxes,
      contacts,
      conversationDisplayId,
      conversationId,
      selectedContactId,
      visible: true,
    },
    global: {
      stubs: {
        Button: {
          props: ['label'],
          emits: ['click'],
          template:
            '<button type="button" @click="$emit(\'click\')">{{ label }}</button>',
        },
        ConversationBox: true,
        Icon: true,
        SchedulingErrorState: true,
        SchedulingSelectField: {
          props: ['label', 'modelValue', 'options'],
          emits: ['update:modelValue'],
          template: `
            <label>
              {{ label }}
              <select
                :value="modelValue"
                @change="$emit('update:modelValue', Number($event.target.value))"
              >
                <option
                  v-for="option in options"
                  :key="option.value"
                  :value="option.value"
                >
                  {{ option.label }}
                </option>
              </select>
            </label>
          `,
        },
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

  it('shows the add contact action when the deal has no linked chat or contacts', async () => {
    const wrapper = mountPanel({
      contacts: [],
      conversationDisplayId: '',
      conversationId: '',
    });

    await flushPromises();
    await wrapper.find('button').trigger('click');

    expect(wrapper.text()).toContain('No dialog linked');
    expect(wrapper.emitted('addContact')).toHaveLength(1);
    expect(dispatch).not.toHaveBeenCalledWith(
      'getConversation',
      expect.anything()
    );
  });

  it('emits createConversation with selected contact and inbox when no chat is linked', async () => {
    const wrapper = mountPanel({
      contactableInboxes: [
        {
          id: 9,
          label: 'Support (email@example.com)',
          sourceId: 'email@example.com',
          value: 9,
        },
      ],
      contacts: [{ id: 7, label: 'John', value: 7 }],
      conversationDisplayId: '',
      conversationId: '',
      selectedContactId: 7,
    });

    await flushPromises();
    await wrapper.find('button').trigger('click');

    expect(wrapper.emitted('createConversation')?.[0]).toEqual([
      expect.objectContaining({
        contactId: 7,
        inboxId: 9,
        inbox: expect.objectContaining({ sourceId: 'email@example.com' }),
      }),
    ]);
  });
});
