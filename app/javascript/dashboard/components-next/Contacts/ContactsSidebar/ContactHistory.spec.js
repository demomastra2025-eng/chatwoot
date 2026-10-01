import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

import ContactHistory from './ContactHistory.vue';

const { getters } = vi.hoisted(() => ({ getters: {} }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: 7, contactId: 3 } }),
}));

vi.mock('dashboard/composables/store', async () => {
  const { computed } = await vi.importActual('vue');
  return { useMapGetter: key => computed(() => getters[key]) };
});

const setConversations = conversations => {
  getters['contactConversations/getAllConversationsByContactId'] = () =>
    conversations;
  getters['contactConversations/getUIFlags'] = { isFetching: false };
  getters['contacts/getContactById'] = () => ({});
  getters['inboxes/getInboxById'] = () => ({});
  getters['labels/getLabels'] = [];
};

const createWrapper = sharedPhone =>
  mount(ContactHistory, {
    props: { sharedPhone },
    global: {
      stubs: {
        ConversationCard: {
          template: '<div data-testid="conversation-card" />',
        },
        ContactNotificationRoute: {
          props: ['notificationRoute', 'hasOwnChats'],
          template: '<div data-testid="route-block" :data-own="hasOwnChats" />',
        },
      },
    },
  });

describe('ContactHistory', () => {
  const route = { kind: 'booking_chat', contact: { id: 11, name: 'Mother' } };

  it('shows the notification route instead of the empty state for a patient card without chats', () => {
    setConversations([]);
    const wrapper = createWrapper({ patient_card: true, route });

    expect(
      wrapper.find('[data-testid="route-block"]').attributes('data-own')
    ).toBe('false');
    expect(wrapper.text()).not.toContain(
      'CONTACTS_LAYOUT.SIDEBAR.HISTORY.EMPTY_STATE'
    );
    expect(wrapper.findAll('[data-testid="conversation-card"]')).toHaveLength(
      0
    );
  });

  it('lists only the card own conversations next to the route block', () => {
    setConversations([{ id: 5, inboxId: 1, meta: { sender: { id: 3 } } }]);
    const wrapper = createWrapper({ patient_card: true, route });

    expect(wrapper.findAll('[data-testid="conversation-card"]')).toHaveLength(
      1
    );
    expect(
      wrapper.find('[data-testid="route-block"]').attributes('data-own')
    ).toBe('true');
  });

  it('keeps the empty state for ordinary contacts', () => {
    setConversations([]);
    const wrapper = createWrapper(null);

    expect(wrapper.text()).toContain(
      'CONTACTS_LAYOUT.SIDEBAR.HISTORY.EMPTY_STATE'
    );
    expect(wrapper.find('[data-testid="route-block"]').exists()).toBe(false);
  });
});
