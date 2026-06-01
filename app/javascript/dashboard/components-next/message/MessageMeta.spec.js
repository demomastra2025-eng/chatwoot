import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';

import MessageMeta from './MessageMeta.vue';
import { MESSAGE_STATUS, MESSAGE_TYPES } from './constants';

const routerMocks = vi.hoisted(() => ({
  push: vi.fn(),
  route: {
    params: {
      accountId: '530',
      conversation_id: '5',
    },
  },
}));

vi.mock('vue-router', () => ({
  useRoute: () => routerMocks.route,
  useRouter: () => ({
    push: routerMocks.push,
  }),
}));

vi.mock('shared/helpers/timeHelper', () => ({
  messageTimestamp: vi.fn(() => 'Mar 26, 6:51 AM'),
}));

const useInboxMock = vi.fn();
vi.mock('dashboard/composables/useInbox', () => ({
  useInbox: () => useInboxMock(),
}));

const useMessageContextMock = vi.fn();
vi.mock('./provider.js', () => ({
  useMessageContext: () => useMessageContextMock(),
}));

const baseInboxState = () => ({
  isAFacebookInbox: ref(false),
  isALineChannel: ref(false),
  isAPIInbox: ref(false),
  isASmsInbox: ref(false),
  isATelegramChannel: ref(false),
  isATelegramPersonalChannel: ref(false),
  isATwilioChannel: ref(false),
  isAWebWidgetInbox: ref(false),
  isAWhatsAppChannel: ref(false),
  isAWhatsAppWebChannel: ref(true),
  isAnEmailChannel: ref(false),
  isAnInstagramChannel: ref(false),
  isATiktokChannel: ref(false),
});

const baseMessageContext = status => ({
  status: ref(status),
  isPrivate: ref(false),
  createdAt: ref(1774504297),
  sourceId: ref('A59662051F54F088C7D7C25E1C02FBF1'),
  messageType: ref(MESSAGE_TYPES.OUTGOING),
  additionalAttributes: ref({}),
  contentAttributes: ref({ externalEcho: true }),
  attachments: ref([]),
  orientation: ref('right'),
});

const mountComponent = () =>
  shallowMount(MessageMeta, {
    global: {
      stubs: {
        Icon: true,
        MessageStatus: {
          name: 'MessageStatus',
          props: ['status'],
          template: '<div />',
        },
      },
    },
  });

describe('MessageMeta', () => {
  beforeEach(() => {
    routerMocks.push.mockClear();
    routerMocks.route.params = {
      accountId: '530',
      conversation_id: '5',
    };
    useInboxMock.mockReturnValue(baseInboxState());
  });

  it.each([
    [MESSAGE_STATUS.SENT, MESSAGE_STATUS.SENT],
    [MESSAGE_STATUS.DELIVERED, MESSAGE_STATUS.DELIVERED],
    [MESSAGE_STATUS.READ, MESSAGE_STATUS.READ],
  ])(
    'shows %s status for WhatsApp Web outgoing messages',
    (messageStatus, expectedStatus) => {
      useMessageContextMock.mockReturnValue(baseMessageContext(messageStatus));

      const wrapper = mountComponent();

      expect(
        wrapper.findComponent({ name: 'MessageStatus' }).props('status')
      ).toBe(expectedStatus);
    }
  );

  it('shows read status for Telegram Personal outgoing messages', () => {
    useInboxMock.mockReturnValue({
      ...baseInboxState(),
      isAWhatsAppWebChannel: ref(false),
      isATelegramPersonalChannel: ref(true),
    });
    useMessageContextMock.mockReturnValue(
      baseMessageContext(MESSAGE_STATUS.READ)
    );

    const wrapper = mountComponent();

    expect(
      wrapper.findComponent({ name: 'MessageStatus' }).props('status')
    ).toBe(MESSAGE_STATUS.READ);
  });

  it('shows an edited marker when the message content was updated', () => {
    useMessageContextMock.mockReturnValue({
      ...baseMessageContext(MESSAGE_STATUS.READ),
      contentAttributes: ref({ edited: true }),
    });

    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('edited');
  });

  it('shows a humanized subagent name when agentName is present', () => {
    useMessageContextMock.mockReturnValue({
      ...baseMessageContext(MESSAGE_STATUS.READ),
      additionalAttributes: ref({ agentName: 'scenario_35_andalusiya_agent' }),
      contentAttributes: ref({}),
    });

    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('Andalusiya');
    expect(wrapper.text()).not.toContain('scenario_35_andalusiya_agent');
  });

  it('keeps spaces and Cyrillic characters in the existing agentName field', () => {
    useMessageContextMock.mockReturnValue({
      ...baseMessageContext(MESSAGE_STATUS.READ),
      additionalAttributes: ref({ agentName: 'AI менеджер' }),
      contentAttributes: ref({}),
    });

    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('AI менеджер');
  });

  it('shows a compact Captain logs action in the metadata row', async () => {
    useMessageContextMock.mockReturnValue({
      ...baseMessageContext(MESSAGE_STATUS.READ),
      additionalAttributes: ref({
        captain_trace: {
          trace_id: 'trace-1',
          session_id: 'session-1',
        },
      }),
      contentAttributes: ref({}),
    });

    const wrapper = mountComponent();
    const logsButton = wrapper.find('[data-testid="captain-trace-logs"]');

    expect(logsButton.exists()).toBe(true);
    expect(logsButton.text()).toBe('Logs');
    expect(wrapper.find('time').element.nextElementSibling).toBe(
      logsButton.element
    );
    expect(wrapper.find('.message-meta-root').classes()).toContain('text-xs');
    expect(logsButton.classes()).not.toContain('ltr:mr-auto');
    expect(logsButton.classes()).not.toContain('font-mono');
    expect(logsButton.classes()).not.toContain('text-[10px]');
    expect(logsButton.find('i').classes()).toContain('i-lucide-file-text');
    expect(logsButton.find('i').classes()).toContain('size-3');

    await logsButton.trigger('click');

    expect(routerMocks.push).toHaveBeenCalledWith({
      name: 'captain_observability_index',
      params: { accountId: '530' },
      query: {
        tab: 'traces',
        trace_id: 'trace-1',
        session_id: 'session-1',
        conversation_display_id: '5',
      },
    });
  });

  it('does not show a sending status for native AI voice transcript messages', () => {
    useMessageContextMock.mockReturnValue({
      ...baseMessageContext(MESSAGE_STATUS.SENT),
      contentAttributes: ref({
        data: {
          type: 'ai_voice_transcript_turn',
          speaker: 'ai',
        },
      }),
    });

    const wrapper = mountComponent();

    expect(wrapper.findComponent({ name: 'MessageStatus' }).exists()).toBe(
      false
    );
  });
});
