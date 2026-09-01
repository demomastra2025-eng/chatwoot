import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import ConversationCard from './ConversationCard.vue';

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  mapGetters: {},
  storeGetters: {},
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: mocks.routerPush }),
}));

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
        InboxName: true,
        ConversationContextMenu: true,
        TimeAgo: true,
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

const findTimeAgoByTestId = (wrapper, testId) =>
  wrapper
    .findAllComponents({ name: 'TimeAgo' })
    .find(component => component.attributes('data-test-id') === testId);

describe('ConversationCard', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  beforeEach(() => {
    window.history.replaceState({}, '', '/');
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
      expect.objectContaining({
        path: '/app/accounts/530/communication_threads/5',
      })
    );
  });

  it('keeps the thread URL clean while preserving list return state', async () => {
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

    expect(mocks.routerPush).toHaveBeenCalledWith({
      path: '/app/accounts/530/communication_threads/5',
      state: {
        conversationListReturnPath: {
          accountId: '530',
          threadId: '5',
          path: '/app/accounts/530/communication_threads?status=open&assignee_type=all',
        },
      },
    });
  });

  it('does not include an explicit assignee tab in a communication thread URL', async () => {
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

    expect(mocks.routerPush).toHaveBeenCalledWith({
      path: '/app/accounts/530/communication_threads/5',
      state: {
        conversationListReturnPath: {
          accountId: '530',
          threadId: '5',
          path: '/app/accounts/530/communication_threads?status=open&assignee_type=all',
        },
      },
    });
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
      expect.objectContaining({
        path: '/app/accounts/530/communication_threads/5',
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

  it('passes an empty string to Avatar when the contact is not loaded', () => {
    mocks.storeGetters['contacts/getContact'].mockReturnValue(undefined);

    const wrapper = mountComponent();

    expect(wrapper.findComponent({ name: 'Avatar' }).props('name')).toBe('');
  });

  it('renders a symmetric full-card separator below the timestamp', () => {
    const wrapper = mountComponent();
    const separator = wrapper.find(
      '[data-test-id="conversation-card-separator"]'
    );

    expect(separator.classes()).toEqual(
      expect.arrayContaining(['absolute', 'bottom-0', 'left-3', 'right-3'])
    );
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
        'bg-n-blue-3',
        'text-n-blue-11',
      ])
    );
    expect(appointmentSticker.attributes('title')).toBe(
      'SCHEDULING.APPOINTMENT_STATUS.confirmed · 2 / SCHEDULING.APPOINTMENT_STATUS.completed'
    );
    expect(appointmentSticker.find('.i-lucide-badge-check').exists()).toBe(
      true
    );
  });

  it('does not render left card accents for appointment-only cards', () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        scheduling_appointment_statuses: [{ status: 'scheduled', count: 1 }],
      },
    });

    expect(
      wrapper.find('[data-test-id="conversation-card-accents"]').exists()
    ).toBe(false);
    expect(
      wrapper
        .find('[data-test-id="conversation-appointment-status-sticker"]')
        .exists()
    ).toBe(true);
  });

  it('renders only the channel icon without the channel name', () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        last_incoming_message_at: 1710000000,
        last_outgoing_message_at: 1710003600,
      },
    });
    expect(
      findTimeAgoByTestId(wrapper, 'conversation-directional-message-times')
    ).toBe(undefined);
    expect(wrapper.findComponent({ name: 'InboxName' }).exists()).toBe(false);
    const channelIcon = wrapper.findComponent({ name: 'ChannelIcon' });
    expect(channelIcon.exists()).toBe(true);
    expect(channelIcon.props('fallbackIcon')).toBe(
      'i-lucide-circle-question-mark'
    );
    expect(channelIcon.props('fallbackIconClass')).toBe('!size-2.5');
  });

  it('does not render a channel name inside a specific inbox route', () => {
    mocks.mapGetters.getSelectedInbox = getter(4593);

    const wrapper = mountComponent();
    expect(wrapper.findComponent({ name: 'InboxName' }).exists()).toBe(false);
    expect(wrapper.findComponent({ name: 'ChannelIcon' }).exists()).toBe(true);
  });

  it('renders the delivery status before an outgoing message preview', () => {
    const wrapper = mountComponent({
      showAssignee: true,
      chat: {
        ...baseChat,
        meta: {
          sender: { id: 1 },
          assignee: { id: 23, name: 'Manager' },
        },
        messages: [
          {
            id: 99,
            content: 'Reply',
            message_type: 1,
            status: 'read',
            created_at: 1710000100,
          },
        ],
      },
    });

    const messageStatus = wrapper.findComponent(
      '[data-test-id="conversation-message-status"]'
    );
    expect(messageStatus.props('status')).toBe('read');
    expect(messageStatus.classes()).toContain('!size-3');
    expect(
      wrapper
        .findComponent({ name: 'MessagePreview' })
        .props('showDirectionIcon')
    ).toBe(false);
    expect(wrapper.find('h4').text()).toContain('Manager');
  });

  it('renders the sending indicator smaller than confirmed statuses', () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        messages: [
          {
            id: 99,
            content: 'Sending',
            message_type: 1,
            status: 'progress',
            created_at: 1710000100,
          },
        ],
      },
    });

    const messageStatus = wrapper.findComponent(
      '[data-test-id="conversation-message-status"]'
    );
    expect(messageStatus.classes()).toContain('!size-2.5');
    expect(messageStatus.classes()).not.toContain('!size-3');
  });

  it('does not render a delivery status for an incoming message', () => {
    const wrapper = mountComponent({
      chat: {
        ...baseChat,
        messages: [
          {
            id: 99,
            content: 'Incoming',
            message_type: 0,
            status: 'read',
            created_at: 1710000100,
          },
        ],
      },
    });

    expect(
      wrapper.find('[data-test-id="conversation-message-status"]').exists()
    ).toBe(false);
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
  });

  it('caps contact names while giving channel names extra room before assignee', () => {
    mocks.storeGetters['contacts/getContact'] = vi.fn(() => ({
      id: 1,
      name: 'Very Long Contact Name',
      thumbnail: '',
      availability_status: 'offline',
    }));
    mocks.storeGetters['inboxes/getInbox'] = vi.fn(id => ({
      id,
      name: 'Very Long Inbox Name',
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
    expect(wrapper.findComponent({ name: 'InboxName' }).exists()).toBe(false);
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
            status: 'read',
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
    expect(
      wrapper
        .findComponent('[data-test-id="conversation-message-status"]')
        .props('status')
    ).toBe('read');
    expect(wrapper.findComponent({ name: 'MessagePreview' }).exists()).toBe(
      false
    );
  });
});
