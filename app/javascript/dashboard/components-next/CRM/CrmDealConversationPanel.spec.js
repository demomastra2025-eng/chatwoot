import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import { useMediaQuery } from '@vueuse/core';
import { useMapGetter, useStore } from 'dashboard/composables/store';

import CrmDealConversationPanel from './CrmDealConversationPanel.vue';

vi.mock('dashboard/composables/store');
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));
// The breakpoint is driven by the test; VueUse's own ref lives in another copy
// of Vue here and would not notify the component's computed values.
vi.mock('@vueuse/core', async importOriginal => ({
  ...(await importOriginal()),
  useMediaQuery: vi.fn(),
}));

const mountPanel = ({
  active = true,
  canManage = true,
  communicationThreadDisplayId = '',
  communicationThreadId = '',
  contactableInboxes = [],
  contextLoadError = null,
  contacts = [],
  conversationId = 11963,
  conversationDisplayId = 185,
  placeholderI18nPrefix = 'CRM.DEALS.CONVERSATION_PLACEHOLDER',
  selectedContactId = '',
  showOpenFullScreen = false,
  inline = false,
} = {}) =>
  mount(CrmDealConversationPanel, {
    props: {
      active,
      canManage,
      communicationThreadDisplayId,
      communicationThreadId,
      contactableInboxes,
      contextLoadError,
      contacts,
      conversationDisplayId,
      conversationId,
      placeholderI18nPrefix,
      selectedContactId,
      showOpenFullScreen,
      inline,
      visible: true,
    },
    global: {
      mocks: { $t: key => key },
      stubs: {
        Button: {
          props: ['disabled', 'label'],
          emits: ['click'],
          template:
            '<button type="button" :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
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
  let isWideScreen;

  beforeEach(() => {
    currentChat = ref({});
    conversations = ref([]);
    isWideScreen = ref(false);
    useMediaQuery.mockReturnValue(isWideScreen);

    dispatch = vi.fn(async (action, payload) => {
      if (action === 'getConversation' && payload === 185) {
        conversations.value = [
          {
            id: 185,
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

      if (action === 'clearSelectedState') {
        currentChat.value = {};
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

  it('renders a retryable context error instead of the create placeholder', async () => {
    const wrapper = mountPanel({
      contacts: [{ id: 9, name: 'Customer' }],
      contextLoadError: new Error('context unavailable'),
      conversationDisplayId: '',
      conversationId: '',
    });
    await flushPromises();

    const errorState = wrapper.findComponent({ name: 'SchedulingErrorState' });
    expect(errorState.exists()).toBe(true);
    expect(errorState.props('description')).toBe('context unavailable');
    expect(wrapper.find('select').exists()).toBe(false);

    errorState.vm.$emit('retry');
    expect(wrapper.emitted('retryContext')).toHaveLength(1);
  });

  it('loads and activates the linked conversation by its API display id', async () => {
    const wrapper = mountPanel();
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('getConversation', 185);
    expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
      data: expect.objectContaining({ id: 185 }),
    });
    expect(wrapper.find('conversation-box-stub').exists()).toBe(true);
    expect(wrapper.find('spinner-stub').exists()).toBe(false);
  });

  it('keeps the inline chat mounted for mobile tabs and exposes the full screen action', async () => {
    const wrapper = mountPanel({
      active: false,
      inline: true,
      showOpenFullScreen: true,
    });
    await flushPromises();

    expect(wrapper.find('[class*="lg:w-[42%]"]').exists()).toBe(true);
    expect(wrapper.find('[class*="hidden lg:flex"]').exists()).toBe(true);
    const openButton = wrapper.find('header button');
    expect(openButton.text()).toBe(
      'CRM.DEALS.CONVERSATION_PLACEHOLDER.OPEN_FULL_SCREEN'
    );
    await openButton.trigger('click');
    expect(wrapper.emitted('openFullScreen')).toHaveLength(1);
  });

  describe('inline chat that the Deal tab hides below the lg breakpoint', () => {
    it('follows the lg breakpoint of the layout', () => {
      mountPanel({ inline: true });

      expect(useMediaQuery).toHaveBeenCalledWith('(min-width: 1024px)');
    });

    it('does not select the hidden chat and activates it with its tab', async () => {
      const wrapper = mountPanel({ active: false, inline: true });
      await flushPromises();

      expect(dispatch).not.toHaveBeenCalledWith(
        'getConversation',
        expect.anything()
      );
      expect(dispatch).not.toHaveBeenCalledWith(
        'setActiveChat',
        expect.anything()
      );
      expect(wrapper.find('conversation-box-stub').exists()).toBe(false);

      await wrapper.setProps({ active: true });
      await flushPromises();

      expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
        data: expect.objectContaining({ id: 185 }),
      });
      expect(wrapper.find('conversation-box-stub').exists()).toBe(true);

      dispatch.mockClear();
      await wrapper.setProps({ active: false });
      await flushPromises();

      expect(dispatch).toHaveBeenCalledWith('clearSelectedState');
      expect(wrapper.find('conversation-box-stub').exists()).toBe(false);
      expect(currentChat.value.id).toBeUndefined();

      await wrapper.setProps({ active: true });
      await flushPromises();

      expect(wrapper.find('conversation-box-stub').exists()).toBe(true);
    });

    it('keeps the chat active beside the card on wide screens', async () => {
      isWideScreen.value = true;
      const wrapper = mountPanel({ active: false, inline: true });
      await flushPromises();

      expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
        data: expect.objectContaining({ id: 185 }),
      });
      expect(wrapper.find('conversation-box-stub').exists()).toBe(true);

      isWideScreen.value = false;
      await flushPromises();

      expect(dispatch).toHaveBeenCalledWith('clearSelectedState');
      expect(wrapper.find('conversation-box-stub').exists()).toBe(false);

      isWideScreen.value = true;
      await flushPromises();

      expect(wrapper.find('conversation-box-stub').exists()).toBe(true);
    });

    it('activates the floating panel regardless of the tab state', async () => {
      const wrapper = mountPanel({ active: false, inline: false });
      await flushPromises();

      expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
        data: expect.objectContaining({ id: 185 }),
      });
      expect(wrapper.find('conversation-box-stub').exists()).toBe(true);
    });
  });

  it('closes the floating panel on Escape but keeps the inline one open', async () => {
    const floating = mountPanel();
    const inline = mountPanel({ inline: true });
    await flushPromises();

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));

    expect(floating.emitted('close')).toHaveLength(1);
    expect(inline.emitted('close')).toBeUndefined();
    floating.unmount();
    inline.unmount();
  });

  it('loads by display id when internal id is missing/invalid', async () => {
    mountPanel({ conversationId: '', conversationDisplayId: 185 });
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('getConversation', 185);
    expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
      data: expect.objectContaining({ id: 185 }),
    });
  });

  it('does not resolve a display id as another conversation internal id', async () => {
    const linkedConversation = {
      id: 185,
      inbox_id: 7,
      messages: [{ id: 1 }],
    };
    conversations.value = [
      {
        display_id: 999,
        id: 185,
        inbox_id: 8,
        messages: [{ id: 2 }],
      },
    ];
    dispatch.mockImplementation(async (action, payload) => {
      if (action === 'getConversation' && payload === 185) {
        return linkedConversation;
      }

      if (action === 'setActiveChat') {
        currentChat.value = payload.data;
      }

      return undefined;
    });

    mountPanel();
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('getConversation', 185);
    expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
      data: linkedConversation,
    });
    expect(currentChat.value.id).toBe(185);
  });

  it('parses non-digit conversationDisplayId and still opens', async () => {
    mountPanel({ conversationId: '', conversationDisplayId: '#185' });
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('getConversation', 185);
    expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
      data: expect.objectContaining({ id: 185 }),
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

  it('does not activate a stale conversation after the linked target changes', async () => {
    let resolveFirstConversation;
    dispatch.mockImplementation(async (action, payload) => {
      if (action === 'getConversation' && payload === 185) {
        return new Promise(resolve => {
          resolveFirstConversation = resolve;
        });
      }

      if (action === 'getConversation' && payload === 186) {
        return {
          id: 186,
          inbox_id: 7,
          messages: [{ id: 2 }],
        };
      }

      if (action === 'setActiveChat') {
        currentChat.value = payload.data;
      }

      return undefined;
    });

    const wrapper = mountPanel();
    await vi.waitFor(() => {
      expect(resolveFirstConversation).toBeTypeOf('function');
    });
    await wrapper.setProps({
      conversationDisplayId: 186,
      conversationId: 11964,
    });
    await flushPromises();

    resolveFirstConversation({ id: 185, inbox_id: 7, messages: [{ id: 1 }] });
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('setActiveChat', {
      data: expect.objectContaining({ id: 186 }),
    });
    expect(dispatch).not.toHaveBeenCalledWith('setActiveChat', {
      data: expect.objectContaining({ id: 185 }),
    });
  });

  it('clears a committed chat when the target changes during activation', async () => {
    const firstConversation = {
      id: 185,
      inbox_id: 7,
      messages: [{ id: 1 }],
    };
    conversations.value = [firstConversation];
    let resolveFirstActivation;
    dispatch.mockImplementation((action, payload) => {
      if (action === 'setActiveChat' && payload.data.id === 185) {
        currentChat.value = payload.data;
        return new Promise(resolve => {
          resolveFirstActivation = resolve;
        });
      }

      if (action === 'clearSelectedState') {
        currentChat.value = {};
      }

      return Promise.resolve(undefined);
    });

    const wrapper = mountPanel();
    await vi.waitFor(() => {
      expect(resolveFirstActivation).toBeTypeOf('function');
    });
    expect(currentChat.value.id).toBe(185);

    await wrapper.setProps({
      conversationDisplayId: 186,
      conversationId: 11964,
    });
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('clearSelectedState');
    expect(currentChat.value.id).toBeUndefined();

    resolveFirstActivation();
    await flushPromises();
    expect(currentChat.value.id).toBeUndefined();
  });

  it('shows the configured placeholder and add contact action when no chat or contacts are linked', async () => {
    const wrapper = mountPanel({
      contacts: [],
      conversationDisplayId: '',
      conversationId: '',
      placeholderI18nPrefix: 'SCHEDULING.CONVERSATION_PLACEHOLDER',
    });

    await flushPromises();
    await wrapper.find('button').trigger('click');

    expect(wrapper.text()).toContain(
      'SCHEDULING.CONVERSATION_PLACEHOLDER.TITLE'
    );
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
          label: 'SALEBOT TEST',
          sourceId: 'salebot-source',
          value: 9,
        },
        {
          id: 10,
          label: 'Voice channel',
          sourceId: '+77000000000',
          value: 10,
        },
      ],
      contacts: [{ id: 7, label: 'John', value: 7 }],
      conversationDisplayId: '',
      conversationId: '',
      placeholderI18nPrefix: 'SCHEDULING.CONVERSATION_PLACEHOLDER',
      selectedContactId: 7,
    });

    await flushPromises();
    expect(wrapper.text()).toContain(
      'SCHEDULING.CONVERSATION_PLACEHOLDER.DESCRIPTION'
    );
    expect(wrapper.text()).toContain('SALEBOT TEST');
    expect(wrapper.text()).toContain('Voice channel');
    await wrapper.find('button').trigger('click');

    expect(wrapper.emitted('createConversation')?.[0]).toEqual([
      expect.objectContaining({
        contactId: 7,
        inboxId: 9,
        inbox: expect.objectContaining({ sourceId: 'salebot-source' }),
      }),
    ]);
  });

  it('does not allow dialog creation in read-only mode', async () => {
    const wrapper = mountPanel({
      canManage: false,
      contactableInboxes: [
        { id: 9, label: 'SALEBOT TEST', sourceId: 'salebot-source', value: 9 },
      ],
      contacts: [{ id: 7, label: 'John', value: 7 }],
      conversationDisplayId: '',
      conversationId: '',
      placeholderI18nPrefix: 'SCHEDULING.CONVERSATION_PLACEHOLDER',
      selectedContactId: 7,
    });

    await flushPromises();

    expect(wrapper.find('button').attributes('disabled')).toBeDefined();
    expect(wrapper.emitted('createConversation')).toBeUndefined();
  });
});
