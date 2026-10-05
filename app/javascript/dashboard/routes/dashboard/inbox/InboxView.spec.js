import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import InboxView from './InboxView.vue';

const defaultNotifications = [{ id: 1, primary_actor: { id: 42 } }];

const mocks = vi.hoisted(() => ({
  currentChat: { __v_isRef: true, value: { id: 42 } },
  dispatch: vi.fn(() => Promise.resolve()),
  routerPush: vi.fn(),
  notifications: [],
  uiSettings: { __v_isRef: true, value: {} },
  isFeatureEnabledonAccount: {
    __v_isRef: true,
    value: vi.fn(() => true),
  },
  permissions: ['administrator'],
}));

vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => ({ params: { accountId: '1', id: '42', inboxId: '7' } }),
  useRouter: () => ({ push: mocks.routerPush }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: name => {
    const getters = {
      'notifications/getFilteredNotifications': {
        __v_isRef: true,
        value: () => mocks.notifications,
      },
      getSelectedChat: mocks.currentChat,
      getConversationById: {
        __v_isRef: true,
        value: () => ({ id: 42 }),
      },
      'notifications/getUIFlags': {
        __v_isRef: true,
        value: { isFetching: false },
      },
      'notifications/getMeta': {
        __v_isRef: true,
        get value() {
          return { count: mocks.notifications.length };
        },
      },
      getCurrentAccountId: { __v_isRef: true, value: 1 },
      'accounts/isFeatureEnabledonAccount': mocks.isFeatureEnabledonAccount,
      getCurrentUser: {
        __v_isRef: true,
        get value() {
          return { accounts: [{ id: 1, permissions: mocks.permissions }] };
        },
      },
    };
    return getters[name];
  },
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ uiSettings: mocks.uiSettings }),
}));

vi.mock('dashboard/composables', () => ({ useTrack: vi.fn() }));
vi.mock('shared/helpers/mitt', () => ({ emitter: { emit: vi.fn() } }));

const closedPanels = {
  is_contact_sidebar_open: false,
  is_crm_deal_panel_open: false,
  is_scheduling_appointments_panel_open: false,
};

const mountInboxView = async () => {
  const wrapper = shallowMount(InboxView, {
    global: {
      mocks: { $t: key => key },
    },
  });
  await wrapper.vm.$nextTick();
  return wrapper;
};

describe('InboxView', () => {
  beforeEach(() => {
    mocks.currentChat.value = { id: 42 };
    mocks.isFeatureEnabledonAccount.value = vi.fn(() => true);
    mocks.permissions = ['administrator'];
    mocks.uiSettings.value = { ...closedPanels };
    mocks.notifications = defaultNotifications;
    mocks.dispatch.mockClear();
    mocks.routerPush.mockClear();
  });

  describe('opening the next notification', () => {
    const nextNotification = extra => ({
      id: 2,
      notification_type: 'conversation_assignment',
      primary_actor_id: 43,
      primary_actor_type: 'Conversation',
      primary_actor: { id: 43, meta: {} },
      ...extra,
    });

    it('opens a conversation inside a communication thread in the thread view', async () => {
      mocks.notifications = [
        ...defaultNotifications,
        nextNotification({ communication_thread_id: 9 }),
      ];
      const wrapper = await mountInboxView();

      wrapper.findComponent({ name: 'InboxItemHeader' }).vm.$emit('next');
      await flushPromises();

      expect(mocks.dispatch).toHaveBeenCalledWith(
        'notifications/read',
        expect.objectContaining({ id: 2, primaryActorId: 43 })
      );
      expect(mocks.routerPush).toHaveBeenCalledWith({
        name: 'communication_thread_conversation',
        params: { accountId: '1', communication_thread_id: 9 },
      });
    });

    it('keeps regular conversations in the inbox view', async () => {
      mocks.notifications = [...defaultNotifications, nextNotification()];
      const wrapper = await mountInboxView();

      wrapper.findComponent({ name: 'InboxItemHeader' }).vm.$emit('next');
      await flushPromises();

      expect(mocks.routerPush).toHaveBeenCalledWith({
        name: 'inbox_view_conversation',
        params: { type: 'conversation', id: 43 },
      });
    });
  });

  it.each([
    'is_contact_sidebar_open',
    'is_crm_deal_panel_open',
    'is_scheduling_appointments_panel_open',
  ])('renders the conversation sidebar for %s', async setting => {
    mocks.uiSettings.value = { ...closedPanels, [setting]: true };

    const wrapper = await mountInboxView();

    expect(
      wrapper.findComponent({ name: 'ConversationSidebar' }).exists()
    ).toBe(true);
  });

  it('does not render a persisted deals panel without CRM permission', async () => {
    mocks.permissions = ['custom_role'];
    mocks.uiSettings.value = { ...closedPanels, is_crm_deal_panel_open: true };

    const wrapper = await mountInboxView();

    expect(
      wrapper.findComponent({ name: 'ConversationSidebar' }).exists()
    ).toBe(false);
  });

  it('does not render a persisted appointments panel when scheduling is disabled', async () => {
    mocks.isFeatureEnabledonAccount.value = vi.fn(
      (_accountId, feature) => feature !== 'scheduling'
    );
    mocks.uiSettings.value = {
      ...closedPanels,
      is_scheduling_appointments_panel_open: true,
    };

    const wrapper = await mountInboxView();

    expect(
      wrapper.findComponent({ name: 'ConversationSidebar' }).exists()
    ).toBe(false);
  });
});
