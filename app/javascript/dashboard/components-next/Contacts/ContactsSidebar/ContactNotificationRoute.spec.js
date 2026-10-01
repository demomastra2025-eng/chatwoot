import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

import ContactNotificationRoute from './ContactNotificationRoute.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key} ${JSON.stringify(params)}` : key),
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: 7 } }),
}));

const RouterLinkStub = {
  props: ['to'],
  template: '<a :data-to="JSON.stringify(to)"><slot /></a>',
};

const createWrapper = props =>
  mount(ContactNotificationRoute, {
    props,
    global: { stubs: { 'router-link': RouterLinkStub } },
  });

describe('ContactNotificationRoute', () => {
  it('shows that the card has no own chats and links the chat that carries its notifications', () => {
    const wrapper = createWrapper({
      hasOwnChats: false,
      notificationRoute: {
        kind: 'booking_chat',
        contact: { id: 11, name: 'Mother' },
        masked_phone: '+7 *** ***-**-09',
        conversation_display_id: 42,
      },
    });

    expect(wrapper.text()).toContain(
      'CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE.NO_OWN_CHATS'
    );
    expect(
      wrapper.find('[data-testid="contact-notification-route-via"]').text()
    ).toContain('"name":"Mother","phone":"+7 *** ***-**-09"');
    expect(wrapper.text()).toContain('ROUTE_BOOKING_NOTE');
    const link = wrapper.find(
      '[data-testid="contact-notification-route-link"]'
    );
    expect(JSON.parse(link.attributes('data-to'))).toEqual({
      name: 'inbox_conversation',
      params: { accountId: 7, conversation_id: 42 },
    });
  });

  it('describes the holder chat without the booking note and hides the no-chats line when the card has chats', () => {
    const wrapper = createWrapper({
      hasOwnChats: true,
      notificationRoute: {
        kind: 'holder',
        contact: { id: 11, name: 'Mother' },
        masked_phone: '+7 *** ***-**-09',
      },
    });

    expect(wrapper.text()).not.toContain('NO_OWN_CHATS');
    expect(wrapper.text()).not.toContain('ROUTE_BOOKING_NOTE');
    expect(
      wrapper.find('[data-testid="contact-notification-route-link"]').exists()
    ).toBe(false);
  });

  it('names the own number when the card has one', () => {
    const wrapper = createWrapper({
      notificationRoute: { kind: 'own', masked_phone: '+7 *** ***-**-02' },
    });

    expect(
      wrapper.find('[data-testid="contact-notification-route-own"]').text()
    ).toContain('ROUTE_OWN_NUMBER');
  });

  it('warns that nothing is sent when the number has no verified chat', () => {
    const wrapper = createWrapper({
      hasOwnChats: false,
      notificationRoute: {
        kind: 'unroutable',
        masked_phone: '+7 *** ***-**-09',
      },
    });

    expect(
      wrapper
        .find('[data-testid="contact-notification-route-unroutable"]')
        .text()
    ).toContain('ROUTE_UNROUTABLE {"phone":"+7 *** ***-**-09"}');
    expect(
      wrapper.find('[data-testid="contact-notification-route-link"]').exists()
    ).toBe(false);
    expect(wrapper.text()).not.toContain('ROUTE_VIA_CHAT');
  });

  it('shows no route text for an unknown route kind', () => {
    const wrapper = createWrapper({
      hasOwnChats: true,
      notificationRoute: { kind: 'entity' },
    });

    expect(wrapper.text()).toBe('');
  });
});
