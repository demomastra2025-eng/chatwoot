import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import MessageList from './MessageList.vue';
import { MESSAGE_STATUS, MESSAGE_TYPES } from './constants';

const currentChat = ref({});

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: ref('en'),
    t: key =>
      ({
        'CONVERSATION.DATE_DIVIDER.TODAY': 'Today',
        'CONVERSATION.DATE_DIVIDER.YESTERDAY': 'Yesterday',
      })[key] || key,
  }),
}));

vi.mock('dashboard/composables/store.js', () => ({
  useMapGetter: getter => {
    if (getter === 'getSelectedChat') return currentChat;
    return ref(null);
  },
}));

vi.mock('dashboard/api/inbox/message.js', () => ({
  default: { getPreviousMessages: vi.fn() },
}));

vi.mock('./Message.vue', () => ({
  default: {
    name: 'Message',
    inheritAttrs: false,
    props: {
      groupWithNext: {
        type: Boolean,
        default: false,
      },
    },
    template: '<li data-test-id="message" :data-id="$attrs.id" />',
  },
}));

const atLocalNoon = (year, month, day) =>
  Math.floor(new Date(year, month - 1, day, 12).getTime() / 1000);

const message = overrides => ({
  id: overrides.id,
  message_type: MESSAGE_TYPES.INCOMING,
  status: MESSAGE_STATUS.SENT,
  content: `message ${overrides.id}`,
  content_attributes: {},
  content_type: 'text',
  conversation_id: overrides.conversation_id ?? 20,
  inbox_id: 30,
  created_at: overrides.created_at,
  sender_id: 2,
  sender: { id: 2, type: 'Contact', name: 'Client' },
  ...overrides,
});

const createWrapper = props =>
  shallowMount(MessageList, {
    props: {
      currentUserId: 1,
      messages: [],
      unreadMessageIds: [],
      ...props,
    },
  });

describe('MessageList', () => {
  beforeEach(() => {
    currentChat.value = {};
  });

  it('renders a date divider when messages move to another day', () => {
    const wrapper = createWrapper({
      messages: [
        message({ id: 1, created_at: atLocalNoon(2026, 6, 24) }),
        message({ id: 2, created_at: atLocalNoon(2026, 6, 24) }),
        message({ id: 3, created_at: atLocalNoon(2026, 6, 25) }),
      ],
    });

    const dateDividers = wrapper.findAll('time');

    expect(dateDividers).toHaveLength(2);
    expect(dateDividers[0].attributes('datetime')).toBe('2026-06-24');
    expect(dateDividers[1].attributes('datetime')).toBe('2026-06-25');
    expect(dateDividers[0].classes()).toContain('text-n-slate-11');
    expect(dateDividers[0].classes()).not.toContain('border');
    expect(dateDividers[0].classes()).not.toContain('shadow-sm');
  });

  it('keeps communication-thread inbox labels while adding date dividers', () => {
    currentChat.value = {
      is_communication_thread: true,
      channels: [
        {
          conversation_id: 20,
          inbox_name: 'WhatsApp Sales',
          channel: 'Channel::Whatsapp',
        },
        {
          conversation_id: 21,
          inbox_name: 'Telegram Support',
          channel: 'Channel::Telegram',
        },
      ],
    };

    const wrapper = createWrapper({
      messages: [
        message({
          id: 1,
          conversation_id: 20,
          created_at: atLocalNoon(2026, 6, 24),
        }),
        message({
          id: 2,
          conversation_id: 21,
          created_at: atLocalNoon(2026, 6, 24),
        }),
      ],
    });

    expect(wrapper.text()).toContain('WhatsApp Sales');
    expect(wrapper.text()).toContain('Telegram Support');
    expect(wrapper.findAll('time')).toHaveLength(1);
  });

  it('hides noisy activity messages in a channel timeline', () => {
    const wrapper = createWrapper({
      messages: [
        message({
          id: 1,
          created_at: atLocalNoon(2026, 6, 24),
          message_type: MESSAGE_TYPES.ACTIVITY,
          source_id: 'ai_voice_event:call:ai_speaking:1',
          content: 'AI agent is speaking',
        }),
        message({
          id: 2,
          created_at: atLocalNoon(2026, 6, 24) + 1,
          message_type: MESSAGE_TYPES.ACTIVITY,
          content: 'Conversation assigned to Alex',
        }),
      ],
    });

    const renderedMessages = wrapper.findAllComponents({ name: 'Message' });
    expect(renderedMessages).toHaveLength(1);
    expect(renderedMessages[0].attributes('id')).toBe('2');
  });

  describe('Captain tool lines', () => {
    const toolLine = overrides =>
      message({
        message_type: MESSAGE_TYPES.ACTIVITY,
        source_id: `captain-tool:${overrides.id}`,
        content: 'ИИ Агент выполнил инструмент «search_scheduling_services»',
        content_attributes: {
          data: { type: 'captain_tool_event', event: 'completed' },
        },
        ...overrides,
      });

    const renderedIds = wrapper =>
      wrapper
        .findAllComponents({ name: 'Message' })
        .map(item => item.attributes('id'));

    it('hides the lines and keeps the handoff activity and the AI answer', () => {
      const createdAt = atLocalNoon(2026, 6, 24);
      const wrapper = createWrapper({
        messages: [
          message({ id: 1, created_at: createdAt }),
          toolLine({ id: 2, created_at: createdAt + 1 }),
          toolLine({
            id: 3,
            created_at: createdAt + 2,
            content_attributes: {
              data: { type: 'captain_tool_event', event: 'failed' },
            },
          }),
          message({
            id: 4,
            created_at: createdAt + 3,
            message_type: MESSAGE_TYPES.OUTGOING,
            content: 'AI answer',
          }),
          message({
            id: 5,
            created_at: createdAt + 4,
            message_type: MESSAGE_TYPES.ACTIVITY,
            content: 'Conversation was marked open by AI Agent',
          }),
        ],
      });

      expect(renderedIds(wrapper)).toEqual(['1', '4', '5']);
    });

    it('keeps a human message that only has the same text', () => {
      const createdAt = atLocalNoon(2026, 6, 24);
      const wrapper = createWrapper({
        messages: [
          message({
            id: 1,
            created_at: createdAt,
            content:
              'ИИ Агент выполнил инструмент «search_scheduling_services»',
          }),
        ],
      });

      expect(renderedIds(wrapper)).toEqual(['1']);
    });

    it('creates no date divider for a day that has only hidden lines', () => {
      const wrapper = createWrapper({
        messages: [
          message({ id: 1, created_at: atLocalNoon(2026, 6, 24) }),
          toolLine({ id: 2, created_at: atLocalNoon(2026, 6, 25) }),
          toolLine({ id: 3, created_at: atLocalNoon(2026, 6, 25) + 5 }),
        ],
      });

      expect(wrapper.findAll('time')).toHaveLength(1);
      expect(renderedIds(wrapper)).toEqual(['1']);
    });

    it('still groups the messages around a hidden line', () => {
      const createdAt = atLocalNoon(2026, 6, 24);
      const wrapper = createWrapper({
        messages: [
          message({ id: 1, created_at: createdAt }),
          toolLine({ id: 2, created_at: createdAt + 10 }),
          message({ id: 3, created_at: createdAt + 20 }),
        ],
      });

      const rendered = wrapper.findAllComponents({ name: 'Message' });
      expect(rendered).toHaveLength(2);
      expect(rendered[0].props('groupWithNext')).toBe(true);
    });

    it('hides the lines of every channel in a communication thread', () => {
      currentChat.value = { is_communication_thread: true, channels: [] };
      const createdAt = atLocalNoon(2026, 6, 24);
      const wrapper = createWrapper({
        messages: [
          message({ id: 1, conversation_id: 20, created_at: createdAt }),
          toolLine({ id: 2, conversation_id: 20, created_at: createdAt + 1 }),
          toolLine({ id: 3, conversation_id: 21, created_at: createdAt + 2 }),
          message({
            id: 4,
            conversation_id: 21,
            created_at: createdAt + 3,
            message_type: MESSAGE_TYPES.ACTIVITY,
            content: 'Conversation was marked open by AI Agent',
          }),
        ],
      });

      expect(renderedIds(wrapper)).toEqual(['1', '4']);
    });
  });

  it('deduplicates the same cross-channel activity in a communication thread', () => {
    currentChat.value = { is_communication_thread: true, channels: [] };
    const createdAt = atLocalNoon(2026, 6, 24);
    const wrapper = createWrapper({
      messages: [
        message({
          id: 1,
          conversation_id: 20,
          created_at: createdAt,
          message_type: MESSAGE_TYPES.ACTIVITY,
          content: 'Conversation resolved by Alex',
          additional_attributes: {
            communication_thread_event_id: 'thread-event-1',
          },
        }),
        message({
          id: 2,
          conversation_id: 21,
          created_at: createdAt + 1,
          message_type: MESSAGE_TYPES.ACTIVITY,
          content: 'Conversation resolved by Alex',
          additional_attributes: {
            communication_thread_event_id: 'thread-event-1',
          },
        }),
        message({
          id: 3,
          conversation_id: 21,
          created_at: createdAt + 10,
          message_type: MESSAGE_TYPES.ACTIVITY,
          content: 'Conversation resolved by Alex',
          additional_attributes: {
            communication_thread_event_id: 'thread-event-2',
          },
        }),
      ],
    });

    const renderedMessages = wrapper.findAllComponents({ name: 'Message' });
    expect(renderedMessages.map(item => item.attributes('id'))).toEqual([
      '1',
      '3',
    ]);
  });

  it('preserves independent cross-channel activities with the same text', () => {
    currentChat.value = { is_communication_thread: true, channels: [] };
    const createdAt = atLocalNoon(2026, 6, 24);
    const wrapper = createWrapper({
      messages: [
        message({
          id: 1,
          conversation_id: 20,
          created_at: createdAt,
          message_type: MESSAGE_TYPES.ACTIVITY,
          content: 'Conversation resolved by Alex',
        }),
        message({
          id: 2,
          conversation_id: 21,
          created_at: createdAt,
          message_type: MESSAGE_TYPES.ACTIVITY,
          content: 'Conversation resolved by Alex',
        }),
      ],
    });

    expect(wrapper.findAllComponents({ name: 'Message' })).toHaveLength(2);
  });

  it.each([
    ['automation then employee', true],
    ['employee then automation', false],
  ])('does not group %s messages', (_scenario, automationFirst) => {
    const createdAt = atLocalNoon(2026, 6, 24);
    const employeeMessage = message({
      id: 1,
      created_at: createdAt,
      message_type: MESSAGE_TYPES.OUTGOING,
      sender_id: 7,
      sender: { id: 7, type: 'User', name: 'Agent' },
    });
    const automationMessage = message({
      ...employeeMessage,
      id: 2,
      additional_attributes: {
        automation_rule_id: 24,
        touch_id: 143,
        touch_origin: 'automation',
        touch_source: 'touch',
      },
    });
    const messages = automationFirst
      ? [automationMessage, employeeMessage]
      : [employeeMessage, automationMessage];

    const wrapper = createWrapper({ messages });
    const renderedMessages = wrapper.findAllComponents({ name: 'Message' });

    expect(renderedMessages[0].props('groupWithNext')).toBe(false);
  });

  it.each([
    ['manual employee', {}],
    [
      'automation',
      {
        automation_rule_id: 24,
        touch_id: 143,
        touch_origin: 'automation',
        touch_source: 'touch',
      },
    ],
  ])('keeps same-provenance %s messages grouped', (_scenario, attributes) => {
    const createdAt = atLocalNoon(2026, 6, 24);
    const messages = [1, 2].map(id =>
      message({
        id,
        additional_attributes: attributes,
        created_at: createdAt,
        message_type: MESSAGE_TYPES.OUTGOING,
        sender_id: 7,
        sender: { id: 7, type: 'User', name: 'Agent' },
      })
    );

    const wrapper = createWrapper({ messages });
    const renderedMessages = wrapper.findAllComponents({ name: 'Message' });

    expect(renderedMessages[0].props('groupWithNext')).toBe(true);
  });
});
