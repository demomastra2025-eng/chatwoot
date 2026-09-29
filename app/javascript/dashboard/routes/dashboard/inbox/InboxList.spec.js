import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import types from 'dashboard/store/mutation-types';
import { getters } from 'dashboard/store/modules/notifications/getters';
import { mutations } from 'dashboard/store/modules/notifications/mutations';

import InboxList from './InboxList.vue';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn(() => Promise.resolve()),
  routerPush: vi.fn(),
  routeParams: { accountId: '1' },
  notifications: [],
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ name: 'inbox_view', params: mocks.routeParams }),
  useRouter: () => ({ push: mocks.routerPush, replace: vi.fn() }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: name =>
    ({
      'notifications/getMeta': {
        __v_isRef: true,
        value: { unreadCount: 1, count: 1 },
      },
      'notifications/getUIFlags': {
        __v_isRef: true,
        value: { isFetching: false, isAllNotificationsLoaded: true },
      },
      'notifications/getFilteredNotificationsV4': {
        __v_isRef: true,
        value: () => mocks.notifications,
      },
      'inboxes/getInboxById': { __v_isRef: true, value: () => ({}) },
    })[name],
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ uiSettings: { __v_isRef: true, value: {} } }),
}));

const notificationItem = extra => ({
  id: 5,
  notificationType: 'conversation_mention',
  primaryActorId: 42,
  primaryActorType: 'Conversation',
  primaryActor: { id: 42, inboxId: 7 },
  ...extra,
});

const mountInboxList = () =>
  shallowMount(InboxList, {
    global: {
      mocks: { $t: key => key },
      stubs: { 'router-view': true },
    },
  });

describe('InboxList', () => {
  beforeEach(() => {
    // jsdom does not implement scrollIntoView; the list scrolls the active card.
    Element.prototype.scrollIntoView = vi.fn();
    mocks.dispatch.mockClear();
    mocks.routerPush.mockClear();
    mocks.routeParams = { accountId: '1' };
  });

  it('opens a conversation inside a communication thread in the thread view', async () => {
    mocks.notifications = [notificationItem({ communicationThreadId: 9 })];
    const wrapper = mountInboxList();

    wrapper.findComponent({ name: 'InboxCard' }).vm.$emit('click');
    await flushPromises();

    expect(mocks.dispatch).toHaveBeenCalledWith(
      'notifications/read',
      expect.objectContaining({ id: 5, primaryActorId: 42 })
    );
    expect(mocks.routerPush).toHaveBeenCalledWith({
      name: 'communication_thread_conversation',
      params: { accountId: '1', communication_thread_id: 9 },
    });
  });

  it('opens a realtime notification in the thread view', async () => {
    // notification.created carries Notification#push_event_data (snake_case);
    // the store keeps it as-is and the V4 getter camelCases it for the list.
    const state = { records: {}, meta: {} };
    mutations[types.ADD_NOTIFICATION](state, {
      notification: {
        id: 5,
        notification_type: 'conversation_mention',
        primary_actor_type: 'Conversation',
        primary_actor_id: 42,
        primary_actor: { id: 42, inbox_id: 7 },
        communication_thread_id: 9,
        created_at: 1759100000,
        last_activity_at: 1759100000,
      },
      unread_count: 1,
      count: 1,
    });
    mocks.notifications = getters.getFilteredNotificationsV4(state)({
      sortOrder: 'desc',
    });
    const wrapper = mountInboxList();

    wrapper.findComponent({ name: 'InboxCard' }).vm.$emit('click');
    await flushPromises();

    expect(mocks.routerPush).toHaveBeenCalledWith({
      name: 'communication_thread_conversation',
      params: { accountId: '1', communication_thread_id: 9 },
    });
  });

  it('keeps regular conversations in the inbox view', async () => {
    mocks.notifications = [notificationItem()];
    const wrapper = mountInboxList();

    wrapper.findComponent({ name: 'InboxCard' }).vm.$emit('click');
    await flushPromises();

    expect(mocks.routerPush).toHaveBeenCalledWith({
      name: 'inbox_view_conversation',
      params: { inboxId: 7, type: 'conversation', id: 42 },
    });
  });

  it('does not reopen the conversation that is already shown', async () => {
    mocks.routeParams = { accountId: '1', id: '42' };
    mocks.notifications = [notificationItem()];
    const wrapper = mountInboxList();

    wrapper.findComponent({ name: 'InboxCard' }).vm.$emit('click');
    await flushPromises();

    expect(mocks.routerPush).not.toHaveBeenCalled();
  });
});
