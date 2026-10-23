import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import ru from 'dashboard/i18n/locale/ru';
import Index from './Index.vue';

const translate = (key, params = {}) => {
  const value = key.split('.').reduce((node, part) => node?.[part], ru);
  return typeof value === 'string'
    ? value.replace(/\{(\w+)\}/g, (_match, name) => params[name] ?? '')
    : key;
};

const storeState = vi.hoisted(() => ({ inboxes: [] }));
const i18n = vi.hoisted(() => ({ t: key => key }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: (...args) => i18n.t(...args) }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ({
    get value() {
      return storeState.inboxes;
    },
  }),
  useStoreGetters: () => ({
    'inboxes/getUIFlags': { value: { isFetching: false } },
  }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountScopedRoute: (name, params) => ({ name, params }),
  }),
}));

i18n.t = translate;

const mountList = inboxes => {
  storeState.inboxes = inboxes;

  return mount(Index, {
    global: {
      mocks: { $t: translate },
      stubs: {
        SettingsLayout: {
          template: '<div><slot name="header" /><slot name="body" /></div>',
        },
        BaseSettingsHeader: { template: '<div />' },
        ChannelIcon: { template: '<i />' },
        ChannelName: { template: '<span />' },
        Button: { template: '<button />' },
        Icon: { props: ['icon'], template: '<i :data-icon="icon" />' },
        'router-link': { template: '<a><slot /></a>' },
      },
    },
  });
};

describe('Inbox list page', () => {
  beforeEach(() => {
    storeState.inboxes = [];
  });

  it('shows a disconnected WhatsApp Web channel as "no connection" without technical details', () => {
    const wrapper = mountList([
      {
        id: 1,
        name: 'Sales',
        channel_type: 'Channel::WhatsappWeb',
        phone_number: '+77001234567',
        provider: 'evolution',
        lifecycle_state: 'connected',
        connection_state: 'close',
        last_error: 'Evolution API 500: socket hang up',
        pre_chat_form_enabled: true,
        additional_attributes: {
          evolution: { status: 'connected', connection_state: 'close' },
        },
      },
    ]);
    const text = wrapper.text();

    expect(wrapper.find('[data-test-id="inbox-status-badge"]').text()).toBe(
      'Нет связи'
    );
    expect(wrapper.find('[data-test-id="inbox-status-hint"]').text()).toBe(
      'Канал не работает — подключите заново'
    );
    expect(wrapper.find('[data-test-id="inbox-subtitle"]').text()).toBe(
      '+77001234567'
    );
    [
      'Активен',
      'Close',
      'Связь',
      'Провайдер',
      'Evolution',
      'socket hang up',
      'Синхр',
      'Pre-chat',
    ].forEach(technical => expect(text).not.toContain(technical));
  });

  it('shows a working channel as connected with one subtitle and only the useful tags', () => {
    const wrapper = mountList([
      {
        id: 2,
        name: 'Mail',
        channel_type: 'Channel::Email',
        email: 'info@example.com',
        forward_to_email: 'forward@example.com',
        imap_enabled: true,
        smtp_enabled: true,
        captain_assistant: { id: 5, name: 'Алия' },
      },
    ]);
    const text = wrapper.text();

    expect(wrapper.find('[data-test-id="inbox-status-badge"]').text()).toBe(
      'Подключён'
    );
    expect(wrapper.find('[data-test-id="inbox-status-hint"]').exists()).toBe(
      false
    );
    expect(wrapper.findAll('[data-test-id="inbox-subtitle"]')).toHaveLength(1);
    expect(wrapper.find('[data-test-id="inbox-subtitle"]').text()).toBe(
      'info@example.com'
    );
    expect(text).toContain('ИИ: Алия');
    ['IMAP', 'SMTP', 'Пересылка', 'forward@example.com'].forEach(technical =>
      expect(text).not.toContain(technical)
    );
  });

  it('hides the website pre-chat form tag and the webhook of an API channel', () => {
    const wrapper = mountList([
      {
        id: 3,
        name: 'Site',
        channel_type: 'Channel::WebWidget',
        website_url: 'https://www.example.com/page',
        pre_chat_form_enabled: true,
      },
      {
        id: 4,
        name: 'Zeta API',
        channel_type: 'Channel::Api',
        webhook_url: 'https://hooks.example.com/chat',
      },
    ]);
    const text = wrapper.text();

    expect(wrapper.find('[data-test-id="inbox-subtitle"]').text()).toBe(
      'example.com'
    );
    expect(wrapper.findAll('[data-test-id="inbox-status-badge"]')).toHaveLength(
      2
    );
    expect(text).not.toContain('Pre-chat');
    expect(text).not.toContain('Вебхук');
    expect(text).not.toContain('hooks.example.com');
  });
});
