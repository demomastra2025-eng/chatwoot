import { beforeEach, describe, expect, it, vi } from 'vitest';
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

describe('ConversationCard', () => {
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
      '/app/accounts/530/communication_threads/5?status=open&assignee_type=me'
    );
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
      '/app/accounts/530/communication_threads/5?status=open&assignee_type=all'
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
      '/app/accounts/530/communication_threads/5?status=open&assignee_type=me'
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
      '/app/accounts/530/communication_threads/5?status=open&assignee_type=me'
    );
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

  it('renders compact time under the avatar and compact inbox name inline with the contact', () => {
    const wrapper = mountComponent();
    const timeAgo = wrapper.findComponent({ name: 'TimeAgo' });
    const inboxName = wrapper.findComponent({ name: 'InboxName' });

    expect(timeAgo.exists()).toBe(true);
    expect(timeAgo.props('displayMode')).toBe('compact_elapsed');
    expect(inboxName.exists()).toBe(true);
    expect(inboxName.props('compact')).toBe(true);
  });

  it('keeps the inbox name visible inside a specific inbox route', () => {
    mocks.mapGetters.getSelectedInbox = getter(4593);

    const wrapper = mountComponent();
    const inboxName = wrapper.findComponent({ name: 'InboxName' });

    expect(inboxName.exists()).toBe(true);
    expect(inboxName.props('inbox')).toEqual({ id: 4593, name: 'Inbox 4593' });
  });

  it('renders outgoing events from inbox to contact in the contact row', () => {
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
            created_at: 1710000100,
          },
        ],
      },
    });

    expect(wrapper.find('.i-lucide-arrow-left').exists()).toBe(true);
    expect(wrapper.find('h4').text()).toContain('Manager');
  });

  it('renders incoming events from contact to inbox in the contact row', () => {
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

    expect(wrapper.find('.i-lucide-arrow-right').exists()).toBe(true);
  });

  it('keeps the activity icon only in the event direction row', () => {
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

    const messagePreview = wrapper.findComponent({ name: 'MessagePreview' });

    expect(wrapper.find('h4 .i-lucide-info').exists()).toBe(true);
    expect(messagePreview.props('showMessageType')).toBe(false);
    expect(messagePreview.classes()).toContain('text-n-slate-11');
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
    expect(
      wrapper.findComponent({ name: 'InboxName' }).props('maxLength')
    ).toBe(15);
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
  });
});
