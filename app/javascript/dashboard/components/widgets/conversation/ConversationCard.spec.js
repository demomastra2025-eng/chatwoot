import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import ConversationCard from './ConversationCard.vue';

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  currentRoute: {
    value: { name: 'communication_threads_dashboard', params: {} },
  },
  mapGetters: {},
  storeGetters: {},
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({
    push: mocks.routerPush,
    currentRoute: mocks.currentRoute,
  }),
}));

const threadPush = (path, query) =>
  expect.objectContaining({
    path,
    query,
  });

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ getters: mocks.storeGetters }),
  useMapGetter: key => mocks.mapGetters[key],
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const getter = value => ({ value });

const baseChat = {
  id: 630,
  inbox_id: 4593,
  timestamp: 1710000000,
  last_incoming_message_at: 1710000000,
  created_at: 1709990000,
  unread_count: 0,
  labels: [],
  custom_attributes: {},
  additional_attributes: {},
  messages: [],
  meta: { sender: { id: 1 } },
  status: 'open',
};

const mountComponent = props =>
  shallowMount(ConversationCard, {
    props: {
      chat: baseChat,
      activeStatus: 'open',
      communicationThreadMode: true,
      ...props,
    },
    global: {
      stubs: {
        Avatar: true,
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

describe('ConversationCard', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  beforeEach(() => {
    window.history.replaceState({}, '', '/');
    window.sessionStorage.clear();
    mocks.currentRoute.value = {
      name: 'communication_threads_dashboard',
      params: {},
    };
    mocks.routerPush.mockClear();
    mocks.mapGetters = {
      getSelectedChat: getter({ id: 630, is_communication_thread: true }),
      'inboxes/getInboxes': getter([{ id: 4593 }, { id: 4674 }]),
      getSelectedInbox: getter(null),
      getCurrentAccountId: getter(530),
    };
    mocks.storeGetters = {
      'contacts/getContact': vi.fn(() => ({
        id: 1,
        name: 'Customer',
        thumbnail: '',
        availability_status: 'offline',
      })),
      'inboxes/getInbox': vi.fn(id => ({ id, name: `Inbox ${id}` })),
    };
  });

  it('does not route a child conversation through communication_threads just because the list is in thread mode', async () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        id: 630,
        inbox_id: 4593,
        is_communication_thread: false,
      },
      communicationThreadMode: true,
    });

    await wrapper.trigger('click');

    expect(mocks.routerPush).toHaveBeenCalledWith(
      '/app/accounts/530/inbox/4593/conversations/630?status=open'
    );
  });

  it('routes actual communication threads by chat type even outside thread list mode', async () => {
    mocks.mapGetters.getSelectedChat = getter({ id: 999 });
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        id: 5,
        communication_thread_id: 5,
        is_communication_thread: true,
      },
      communicationThreadMode: false,
    });

    await wrapper.trigger('click');

    expect(mocks.routerPush).toHaveBeenCalledWith(
      threadPush('/app/accounts/530/communication_threads/5', {
        status: 'open',
        assignee_type: 'all',
      })
    );
  });

  it('remembers the filtered list URL when opening a communication thread', async () => {
    window.history.replaceState(
      {},
      '',
      '/app/accounts/530/communication_threads?status=pending&crm_stage_id=20'
    );
    mocks.mapGetters.getSelectedChat = getter({ id: 999 });
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        id: 5,
        communication_thread_id: 5,
        is_communication_thread: true,
      },
      activeStatus: 'pending',
      communicationThreadMode: true,
    });

    await wrapper.trigger('click');

    const listPath =
      '/app/accounts/530/communication_threads?status=pending&crm_stage_id=20';
    const [[pushArg]] = mocks.routerPush.mock.calls;
    expect(pushArg.path).toBe('/app/accounts/530/communication_threads/5');
    expect(pushArg.query).toMatchObject({
      status: 'pending',
      assignee_type: 'all',
    });
    expect(pushArg.state).toEqual({
      conversationListReturnPath: {
        accountId: '530',
        threadId: '5',
        path: listPath,
      },
    });
    expect(
      window.sessionStorage.getItem('conversation_list_return_path:530:5')
    ).toBe(listPath);
  });

  it('keeps the original list when switching from one open thread to another', async () => {
    const listPath =
      '/app/accounts/530/custom_view/9/conversations?status=open';
    window.sessionStorage.setItem(
      'conversation_list_return_path:530:4',
      listPath
    );
    window.history.replaceState(
      {},
      '',
      '/app/accounts/530/communication_threads/4?status=open'
    );
    mocks.currentRoute.value = {
      name: 'communication_thread_conversation',
      params: { communication_thread_id: '4' },
    };
    mocks.mapGetters.getSelectedChat = getter({
      id: 4,
      is_communication_thread: true,
    });
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        id: 5,
        communication_thread_id: 5,
        is_communication_thread: true,
      },
      communicationThreadMode: true,
    });

    await wrapper.trigger('click');

    expect(
      window.sessionStorage.getItem('conversation_list_return_path:530:5')
    ).toBe(listPath);
    expect(mocks.routerPush.mock.calls[0][0].state).toEqual({
      conversationListReturnPath: {
        accountId: '530',
        threadId: '5',
        path: listPath,
      },
    });
  });

  it('preserves the assignee tab query when opening a communication thread', async () => {
    window.history.replaceState(
      {},
      '',
      '/app/accounts/530/communication_threads?status=open&assignee_type=all'
    );
    mocks.mapGetters.getSelectedChat = getter({ id: 999 });
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        id: 5,
        communication_thread_id: 5,
        is_communication_thread: true,
      },
      activeAssigneeType: 'all',
      communicationThreadMode: true,
    });

    await wrapper.trigger('click');

    expect(mocks.routerPush).toHaveBeenCalledWith(
      threadPush('/app/accounts/530/communication_threads/5', {
        status: 'open',
        assignee_type: 'all',
      })
    );
  });

  it('uses the explicit active assignee tab instead of a stale location fallback', async () => {
    window.history.replaceState(
      {},
      '',
      '/app/accounts/530/communication_threads?status=open&assignee_type=all'
    );
    mocks.mapGetters.getSelectedChat = getter({ id: 999 });
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        id: 5,
        communication_thread_id: 5,
        is_communication_thread: true,
      },
      activeAssigneeType: 'me',
      communicationThreadMode: true,
    });

    await wrapper.trigger('click');

    expect(mocks.routerPush).toHaveBeenCalledWith(
      threadPush('/app/accounts/530/communication_threads/5', {
        status: 'open',
        assignee_type: 'me',
      })
    );
  });

  it('keeps same-id child conversations from being highlighted as active communication threads', () => {
    mocks.mapGetters.getSelectedChat = getter({ id: 630 });
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        id: 630,
        communication_thread_id: 630,
        is_communication_thread: true,
      },
      communicationThreadMode: true,
    });

    expect(wrapper.classes()).not.toContain('active');
  });

  it('treats legacy communication thread payloads with only communication_thread_id as threads', async () => {
    mocks.mapGetters.getSelectedChat = getter({
      id: 5,
      communication_thread_id: 5,
    });
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        id: 5,
        communication_thread_id: 5,
      },
      communicationThreadMode: false,
    });

    await wrapper.trigger('click');

    expect(mocks.routerPush).toHaveBeenCalledWith(
      threadPush('/app/accounts/530/communication_threads/5', {
        status: 'open',
        assignee_type: 'all',
      })
    );
  });

  it('opens the existing context menu as a mobile sheet on long press', async () => {
    vi.useFakeTimers();
    const wrapper = mountComponent({ enableContextMenu: true });

    await wrapper.trigger('touchstart', {
      touches: [{ clientX: 48, clientY: 96 }],
    });
    vi.advanceTimersByTime(550);
    await wrapper.vm.$nextTick();

    const contextMenu = wrapper.findComponent({ name: 'ContextMenu' });

    expect(contextMenu.exists()).toBe(true);
    expect(contextMenu.props()).toMatchObject({ x: 48, y: 96, mobile: true });

    await wrapper.trigger('touchend');
    await wrapper.trigger('click');

    expect(mocks.routerPush).not.toHaveBeenCalled();
  });

  it('cancels mobile long press when the user scrolls the chat list', async () => {
    vi.useFakeTimers();
    const wrapper = mountComponent({ enableContextMenu: true });

    await wrapper.trigger('touchstart', {
      touches: [{ clientX: 48, clientY: 96 }],
    });
    await wrapper.trigger('touchmove', {
      touches: [{ clientX: 48, clientY: 120 }],
    });
    vi.advanceTimersByTime(550);
    await wrapper.vm.$nextTick();

    expect(wrapper.findComponent({ name: 'ContextMenu' }).exists()).toBe(false);
  });

  it('keeps the unread badge as the unread message count', () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        unread_count: 7,
        messages: [
          {
            id: 10,
            content: 'Unread',
            message_type: 0,
            created_at: 1710000100,
          },
        ],
      },
    });

    const unreadBadge = wrapper.find('.bg-n-brand-solid');
    expect(unreadBadge.exists()).toBe(true);
    expect(unreadBadge.text()).toBe('7');
    expect(unreadBadge.classes()).toContain('rounded-full');
    expect(unreadBadge.element.parentElement).toBe(
      wrapper.findComponent({ name: 'MessagePreview' }).element.parentElement
    );
  });

  it('renders a smaller avatar in the conversation list', () => {
    const wrapper = mountComponent();

    expect(wrapper.findComponent({ name: 'Avatar' }).props('size')).toBe(28);
  });

  it('passes an empty name to Avatar when the contact is not loaded', () => {
    mocks.storeGetters['contacts/getContact'].mockReturnValue(undefined);

    const wrapper = mountComponent();

    expect(wrapper.findComponent({ name: 'Avatar' }).props('name')).toBe('');
  });

  it('renders a symmetric full-card separator instead of a content border', () => {
    const wrapper = mountComponent();
    const separator = wrapper.find(
      '[data-test-id="conversation-card-separator"]'
    );

    expect(separator.classes()).toEqual(
      expect.arrayContaining(['absolute', 'bottom-0', 'left-3', 'right-3'])
    );
    expect(wrapper.find('.border-b').exists()).toBe(false);
  });

  it('does not render CRM stage color accents on the card edge', () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        crm_deal_stages: [
          { id: 10, name: 'New', color: '#22C55E' },
          { id: 20, name: 'Qualified', color: '#3B82F6' },
        ],
      },
    });

    expect(
      wrapper.find('[data-test-id="conversation-card-accents"]').exists()
    ).toBe(false);
    expect(
      wrapper.find('[data-test-id="conversation-crm-stage-accents"]').exists()
    ).toBe(false);
  });

  it('renders scheduling appointment status as a sticker over the avatar instead of a dashed rail', () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        crm_deal_stages: [{ id: 10, name: 'New', color: '#22C55E' }],
        scheduling_appointment_statuses: [
          { status: 'confirmed', count: 2 },
          { status: 'completed', count: 1 },
        ],
      },
    });

    const appointmentSticker = wrapper.find(
      '[data-test-id="conversation-appointment-status-sticker"]'
    );

    expect(
      wrapper.find('[data-test-id="conversation-card-accents"]').exists()
    ).toBe(false);
    expect(
      wrapper
        .find('[data-test-id="conversation-appointment-status-accents"]')
        .exists()
    ).toBe(false);
    expect(wrapper.find('.appointment-status-dashed-rail').exists()).toBe(
      false
    );
    expect(appointmentSticker.exists()).toBe(true);
    expect(appointmentSticker.element.parentElement).toBe(
      wrapper.findComponent({ name: 'Avatar' }).element.parentElement
    );
    expect(appointmentSticker.classes()).toEqual(
      expect.arrayContaining([
        'absolute',
        'right-0',
        'top-2',
        'rounded-full',
        'bg-n-teal-3',
        'text-n-teal-11',
      ])
    );
    expect(appointmentSticker.attributes('title')).toBe(
      'SCHEDULING.APPOINTMENT_STATUS.confirmed · 2 / SCHEDULING.APPOINTMENT_STATUS.completed'
    );
    expect(appointmentSticker.find('.i-lucide-badge-check').exists()).toBe(
      true
    );
  });

  describe('last message time under the avatar', () => {
    const localTimestamp = (...parts) =>
      Math.floor(new Date(...parts).getTime() / 1000);
    const mountWithMessageAt = createdAt =>
      mountComponent({
        chat: {
          ...baseChat,
          messages: [
            {
              id: 99,
              content: 'Hello',
              message_type: 0,
              created_at: createdAt,
            },
          ],
        },
      });
    const timeLabel = wrapper =>
      wrapper.find('[data-test-id="conversation-card-last-message-time"]');

    beforeEach(() => {
      vi.useFakeTimers();
      vi.setSystemTime(new Date(2024, 2, 9, 18, 30, 0));
    });

    it('shows the clock time for a message from today', () => {
      const createdAt = localTimestamp(2024, 2, 9, 9, 5);
      const wrapper = mountWithMessageAt(createdAt);

      expect(timeLabel(wrapper).text()).toBe(
        new Intl.DateTimeFormat('en', {
          hour: '2-digit',
          minute: '2-digit',
        }).format(new Date(createdAt * 1000))
      );
      expect(timeLabel(wrapper).element.parentElement).toBe(
        wrapper.findComponent({ name: 'Avatar' }).element.parentElement
      );
    });

    it('shows yesterday for a message from the previous day', () => {
      const wrapper = mountWithMessageAt(localTimestamp(2024, 2, 8, 23, 50));

      expect(timeLabel(wrapper).text()).toBe(
        'CONVERSATION.DATE_DIVIDER.YESTERDAY'
      );
    });

    it('shows a short date for older messages of the current year', () => {
      const createdAt = localTimestamp(2024, 0, 15, 12, 0);
      const wrapper = mountWithMessageAt(createdAt);

      expect(timeLabel(wrapper).text()).toBe(
        new Intl.DateTimeFormat('en', {
          day: 'numeric',
          month: 'short',
        }).format(new Date(createdAt * 1000))
      );
    });

    it('shows a numeric date for messages from previous years', () => {
      const createdAt = localTimestamp(2023, 11, 31, 12, 0);
      const wrapper = mountWithMessageAt(createdAt);

      expect(timeLabel(wrapper).text()).toBe(
        new Intl.DateTimeFormat('en', {
          day: '2-digit',
          month: '2-digit',
          year: '2-digit',
        }).format(new Date(createdAt * 1000))
      );
    });

    it('does not render the directional activity timer anymore', () => {
      const wrapper = mountWithMessageAt(localTimestamp(2024, 2, 9, 9, 5));

      expect(wrapper.findComponent({ name: 'TimeAgo' }).exists()).toBe(false);
    });
  });

  it('renders only the channel icon without the channel name', () => {
    const wrapper = mountComponent();
    const channelIcon = wrapper.findComponent({ name: 'ChannelIcon' });

    expect(wrapper.findComponent({ name: 'InboxName' }).exists()).toBe(false);
    expect(channelIcon.exists()).toBe(true);
    expect(channelIcon.props('inbox')).toEqual({
      id: 4593,
      name: 'Inbox 4593',
    });
    expect(channelIcon.props('fallbackIcon')).toBe(
      'i-lucide-circle-question-mark'
    );
    expect(channelIcon.props('fallbackIconClass')).toBe('!size-2.5');
    expect(wrapper.find('.i-lucide-arrow-left').exists()).toBe(false);
    expect(wrapper.find('.i-lucide-arrow-right').exists()).toBe(false);
  });

  it('keeps the assignee in the contact row', () => {
    const wrapper = mountComponent({
      showAssignee: true,
      chat: {
        ...baseChat,
        meta: {
          sender: { id: 1 },
          assignee: { id: 23, name: 'Manager' },
        },
      },
    });

    expect(wrapper.find('h4').text()).toContain('Manager');
  });

  describe('delivery status of the last outgoing message', () => {
    const whatsappInbox = id => ({
      id,
      name: `Inbox ${id}`,
      channel_type: 'Channel::Whatsapp',
    });
    const mountWithOutgoing = message =>
      mountComponent({
        chat: {
          ...baseChat,
          messages: [
            {
              id: 99,
              content: 'Reply',
              message_type: 1,
              created_at: 1710000100,
              ...message,
            },
          ],
        },
      });

    beforeEach(() => {
      mocks.storeGetters['inboxes/getInbox'] = vi.fn(whatsappInbox);
    });

    it('keeps the sending indicator until the provider confirms the message', () => {
      const wrapper = mountWithOutgoing({ status: 'sent' });
      const messageStatus = wrapper.findComponent({ name: 'MessageStatus' });

      expect(messageStatus.props('status')).toBe('progress');
      expect(messageStatus.classes()).toContain('!size-2.5');
      expect(messageStatus.classes()).not.toContain('!size-3');
    });

    it('renders the confirmed status before the preview without a reply arrow', () => {
      const wrapper = mountWithOutgoing({
        status: 'read',
        source_id: 'wamid.1',
      });
      const messageStatus = wrapper.findComponent({ name: 'MessageStatus' });

      expect(messageStatus.props('status')).toBe('read');
      expect(messageStatus.classes()).toContain('!size-3');
      expect(
        wrapper
          .findComponent({ name: 'MessagePreview' })
          .props('showDirectionIcon')
      ).toBe(false);
    });

    it('uses the channel of the last message inside a communication thread', () => {
      mocks.storeGetters['inboxes/getInbox'] = vi.fn(id =>
        id === 77
          ? { id, name: 'Web', channel_type: 'Channel::WebWidget' }
          : whatsappInbox(id)
      );
      const wrapper = mountWithOutgoing({ status: 'sent', inbox_id: 77 });

      expect(
        wrapper.findComponent({ name: 'MessageStatus' }).props('status')
      ).toBe('delivered');
    });

    it('does not render a delivery status for an incoming message', () => {
      const wrapper = mountWithOutgoing({ message_type: 0, status: 'read' });

      expect(wrapper.findComponent({ name: 'MessageStatus' }).exists()).toBe(
        false
      );
    });
  });

  it('hides system activity content and its timestamp from the list', () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        messages: [
          {
            id: 99,
            content: 'conversation_status_changed',
            message_type: 2,
            created_at: 1710000100,
          },
        ],
      },
    });

    expect(wrapper.findComponent({ name: 'MessagePreview' }).exists()).toBe(
      false
    );
    expect(wrapper.text()).not.toContain('conversation_status_changed');
    expect(
      wrapper
        .find('[data-test-id="conversation-card-last-message-time"]')
        .exists()
    ).toBe(false);
  });

  it('renders regular message previews with the primary text color', () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        messages: [
          {
            id: 99,
            content: 'Incoming',
            message_type: 0,
            created_at: 1710000100,
          },
        ],
      },
    });

    const messagePreview = wrapper.findComponent({ name: 'MessagePreview' });

    expect(messagePreview.props('showMessageType')).toBe(true);
    expect(messagePreview.classes()).toContain('text-n-slate-12');
    expect(messagePreview.classes()).not.toContain('text-n-slate-11');
    expect(messagePreview.classes()).not.toContain('font-semibold');
  });

  it('renders unread conversations in bold', () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        unread_count: 2,
        messages: [
          {
            id: 99,
            content: 'Incoming',
            message_type: 0,
            created_at: 1710000100,
          },
        ],
      },
    });

    expect(
      wrapper.findComponent({ name: 'MessagePreview' }).classes()
    ).toContain('font-semibold');
    expect(wrapper.find('h4 span').classes()).toContain('font-semibold');
  });

  it('caps contact names before the assignee', () => {
    mocks.storeGetters['contacts/getContact'] = vi.fn(() => ({
      id: 1,
      name: 'Very Long Contact Name',
      thumbnail: '',
      availability_status: 'offline',
    }));

    const wrapper = mountComponent({
      showAssignee: true,
      chat: {
        ...baseChat,
        meta: {
          sender: { id: 1 },
          assignee: { id: 23, name: 'Very Long Manager Name' },
        },
      },
    });

    const contactRow = wrapper.find('h4');
    const assigneeIcon = wrapper.find('fluent-icon-stub[icon="person"]');

    expect(contactRow.text()).toContain('Very Long Co…');
    expect(contactRow.text()).toContain('Very Long Manager Name');
    expect(assigneeIcon.classes()).toContain('flex-shrink-0');
  });

  it('uses the existing voice call status row for communication-thread voice previews', () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        id: 5,
        communication_thread_id: 5,
        is_communication_thread: true,
        messages: [
          {
            id: 4238,
            content: 'Voice Call',
            content_type: 'voice_call',
            message_type: 1,
            content_attributes: {
              data: {
                status: 'completed',
                call_direction: 'outbound',
              },
            },
          },
        ],
      },
      communicationThreadMode: true,
    });

    const voiceCallStatus = wrapper.findComponent({ name: 'VoiceCallStatus' });

    expect(voiceCallStatus.exists()).toBe(true);
    expect(voiceCallStatus.props('status')).toBe('completed');
    expect(voiceCallStatus.props('direction')).toBe('outbound');
    expect(wrapper.findComponent({ name: 'MessagePreview' }).exists()).toBe(
      false
    );
    expect(wrapper.findComponent({ name: 'MessageStatus' }).exists()).toBe(
      false
    );
  });

  it('shows the delivery status in the voice row for provider channels', () => {
    mocks.storeGetters['inboxes/getInbox'] = vi.fn(id => ({
      id,
      name: `Inbox ${id}`,
      channel_type: 'Channel::Whatsapp',
    }));
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        messages: [
          {
            id: 4238,
            content: 'Voice Call',
            content_type: 'voice_call',
            message_type: 1,
            status: 'delivered',
            source_id: 'wacid.1',
            content_attributes: {
              data: { status: 'completed', call_direction: 'outbound' },
            },
          },
        ],
      },
    });

    expect(wrapper.findComponent({ name: 'VoiceCallStatus' }).exists()).toBe(
      true
    );
    expect(
      wrapper.findComponent({ name: 'MessageStatus' }).props('status')
    ).toBe('delivered');
  });
});
