import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import ConversationHeader from './ConversationHeader.vue';

const translate = key =>
  ({
    'CONVERSATION.COMMUNICATION_THREAD.ALL_CHANNELS': 'Все каналы',
    'CONVERSATION.VOICE_WIDGET.UNKNOWN_CALLER': 'Неизвестный',
    'CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.open.TEXT': 'Открыт',
  })[key] || key;

vi.mock('../BackButton.vue', () => ({
  default: { template: '<div data-test-id="back-button" />' },
}));
vi.mock('../InboxName.vue', () => ({
  default: {
    props: ['inbox'],
    template: '<div data-test-id="inbox-name">{{ inbox.name }}</div>',
  },
}));
vi.mock('./MoreActions.vue', () => ({
  default: { template: '<div data-test-id="more-actions" />' },
}));
vi.mock('next/avatar/Avatar.vue', () => ({
  default: { template: '<div data-test-id="avatar" />' },
}));
vi.mock('./components/SLACardLabel.vue', () => ({
  default: { template: '<div data-test-id="sla-card-label" />' },
}));

vi.mock('dashboard/helper/URLHelper', () => ({
  conversationListPageURL: () => '/app/accounts/530/communication_threads',
  frontendURL: path => `/app/${path}`,
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({
    name: 'communication_thread_conversation',
    params: {},
    query: { status: 'open' },
  }),
}));

vi.mock('vuex', () => ({
  createStore: () => ({}),
  useStore: () => ({
    getters: {
      getSelectedChat: { id: 7, status: 'open' },
      getCurrentAccountId: 530,
      'contacts/getContact': () => ({
        id: 1,
        name: 'Аружан',
        phone_number: '+770****1122',
        thumbnail: '',
        availability_status: 'online',
      }),
      'inboxes/getInbox': () => ({ id: 4593, name: '+771****5175' }),
      'inboxes/getInboxes': [{ id: 4593 }, { id: 102 }],
    },
  }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: translate }),
}));

vi.mock('dashboard/composables/useInbox', () => ({
  useInbox: () => ({ isAWebWidgetInbox: { value: false } }),
}));

const mountComponent = props =>
  mount(ConversationHeader, {
    props: {
      chat: {
        id: 7,
        is_communication_thread: true,
        meta: { sender: { id: 1, name: 'Аружан' } },
        channels: [
          {
            conversation_id: 11,
            inbox_id: 101,
            inbox_name: 'Business WhatsApp',
            source_id: '+77000001122',
            channel: 'Channel::WhatsappWeb',
            last_activity_at: 100,
          },
          {
            conversation_id: 22,
            inbox_id: 202,
            inbox_name: 'Business Telegram',
            source_id: 'telegram:business-target',
            channel_profile: { username: 'client_login' },
            channel: 'Channel::Telegram',
            last_activity_at: 200,
          },
        ],
      },
      ...props,
    },
    global: {
      mocks: { $t: translate },
      stubs: {
        Avatar: { template: '<div data-test-id="avatar" />' },
        BackButton: true,
        InboxName: true,
        MoreActions: { template: '<div data-test-id="more-actions" />' },
        SLACardLabel: true,
        FluentIcon: true,
      },
    },
  });

describe('ConversationHeader', () => {
  it('shows communication thread contact identities instead of target inbox names', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('Аружан');
    expect(wrapper.text()).toContain('+77000001122');
    expect(wrapper.text()).toContain('client_login');
    expect(wrapper.text()).not.toContain('Business Telegram');
    expect(wrapper.text()).not.toContain('Business WhatsApp');
    expect(wrapper.text()).not.toContain('Все каналы');
  });

  it('shows direct conversation contact identity instead of the business inbox name', () => {
    const wrapper = mountComponent({
      chat: {
        id: 627,
        inbox_id: 4593,
        meta: {
          sender: { id: 1, name: 'Аружан' },
          contact_inbox: {
            source_id: '+770****1122',
            channel_profile: { username: 'client_login' },
          },
        },
      },
    });

    expect(wrapper.text()).toContain('Аружан');
    expect(wrapper.text()).toContain('+770****1122');
    expect(wrapper.text()).not.toContain('+771****5175');
    expect(wrapper.find('[data-test-id="inbox-name"]').exists()).toBe(false);
  });

  it('keeps the regular header actions available for communication threads', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('[data-test-id="more-actions"]').exists()).toBe(true);
  });
});
