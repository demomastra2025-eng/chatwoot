import { flushPromises, mount } from '@vue/test-utils';
/* eslint-disable vue/one-component-per-file */
import { defineComponent, h } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const { alertMock, dispatch, getters, push } = vi.hoisted(() => ({
  alertMock: vi.fn(),
  dispatch: vi.fn(() => Promise.resolve()),
  push: vi.fn(() => Promise.resolve()),
  getters: {
    accountId: { value: 1 },
    meta: { value: { count: 1, unreadCount: 1 } },
    records: { value: () => [] },
    uiFlags: {
      value: { isFetching: false, isUpdating: false },
    },
  },
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key => {
    const map = {
      getCurrentAccountId: getters.accountId,
      'notifications/getFilteredNotificationsV4': getters.records,
      'notifications/getMeta': getters.meta,
      'notifications/getUIFlags': getters.uiFlags,
    };
    return map[key];
  },
  useStore: () => ({ dispatch }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

import NotificationPanel from './NotificationPanel.vue';

const unreadNotification = (overrides = {}) => ({
  id: 7,
  lastActivityAt: 1_777_777_777,
  primaryActor: { id: 21, inboxId: 5 },
  primaryActorId: 21,
  primaryActorType: 'Conversation',
  pushMessageBody: 'Notification body',
  pushMessageTitle: 'Notification title',
  readAt: null,
  ...overrides,
});

// A server page as the notifications/index action returns it (API payload).
const serverPage = (length, { count = length, firstId = 100 } = {}) => ({
  payload: Array.from({ length }, (_, index) => ({
    id: firstId - index,
    last_activity_at: 1_777_777_000 - index,
  })),
  meta: { count, unread_count: count },
});

const ButtonStub = defineComponent({
  inheritAttrs: false,
  props: {
    disabled: Boolean,
    label: { type: String, default: '' },
  },
  emits: ['click'],
  setup(props, { attrs, emit }) {
    return () =>
      h(
        'button',
        {
          ...attrs,
          disabled: props.disabled,
          onClick: event => emit('click', event),
        },
        props.label
      );
  },
});

const mountPanel = (props = {}) =>
  mount(NotificationPanel, {
    props,
    global: {
      stubs: {
        Button: ButtonStub,
        OnClickOutside: { template: '<div><slot /></div>' },
        Spinner: true,
        TeleportWithDirection: { template: '<div><slot /></div>' },
      },
    },
  });

const dispatchSucceeds = action =>
  Promise.resolve(action === 'notifications/archive' ? true : undefined);

describe('NotificationPanel', () => {
  beforeEach(() => {
    dispatch.mockReset().mockImplementation(dispatchSucceeds);
    push.mockClear();
    alertMock.mockClear();
    getters.meta.value = { count: 1, unreadCount: 1 };
    getters.records.value = () => [unreadNotification()];
  });

  it('opens on new notifications without navigating to a page', async () => {
    const wrapper = mountPanel();

    await wrapper.vm.open();

    expect(dispatch).toHaveBeenNthCalledWith(1, 'notifications/clear');
    expect(dispatch).toHaveBeenNthCalledWith(2, 'notifications/index', {
      page: 1,
      sortOrder: 'desc',
      status: '',
    });
    expect(push).not.toHaveBeenCalled();
    const panel = wrapper.get('.notification-side-panel');
    expect(panel.attributes('role')).toBe('dialog');
    expect(panel.attributes('style')).toContain(
      '--notification-panel-offset: 44px'
    );
    expect(panel.classes()).toContain('w-[26rem]');
    expect(panel.classes()).toContain('max-h-[38rem]');
    expect(panel.classes()).toContain('rounded-2xl');
    expect(panel.classes()).toContain('bottom-1.5');
    expect(wrapper.text()).toContain('Notification title');
    expect(wrapper.text()).toContain('Notification body');

    wrapper.vm.toggle();
    await wrapper.vm.$nextTick();
    expect(wrapper.find('.notification-side-panel').exists()).toBe(false);
  });

  it('uses the primary sidebar offset supplied by the trigger layout', async () => {
    const wrapper = mountPanel({ sidebarOffset: 52 });

    await wrapper.vm.open();

    expect(
      wrapper.get('.notification-side-panel').attributes('style')
    ).toContain('--notification-panel-offset: 52px');
  });

  it('loads archived notifications in the archive tab and read ones in all', async () => {
    const wrapper = mountPanel();
    await wrapper.vm.open();
    dispatch.mockClear();

    await wrapper
      .get('[data-test="notification-tab-archive"]')
      .trigger('click');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('notifications/clear');
    expect(dispatch).toHaveBeenCalledWith('notifications/index', {
      page: 1,
      sortOrder: 'desc',
      status: 'archived',
    });
    expect(
      wrapper
        .get('[data-test="notification-tab-archive"]')
        .attributes('aria-selected')
    ).toBe('true');
    // Unread records never show in the archive tab.
    expect(wrapper.find('[data-test="notification-item"]').exists()).toBe(
      false
    );
    expect(
      wrapper.find('[data-test="notification-panel-empty"]').exists()
    ).toBe(true);

    await wrapper.get('[data-test="notification-tab-all"]').trigger('click');
    await flushPromises();
    expect(dispatch).toHaveBeenLastCalledWith('notifications/index', {
      page: 1,
      sortOrder: 'desc',
      status: 'read',
    });
    expect(wrapper.findAll('[data-test="notification-item"]')).toHaveLength(1);
  });

  it('archives one notification or all notifications', async () => {
    const wrapper = mountPanel();
    await wrapper.vm.open();
    dispatch.mockClear();

    await wrapper.get('[data-test="archive-notification"]').trigger('click');
    expect(dispatch).toHaveBeenCalledWith('notifications/archive', {
      id: 7,
      unreadCount: 1,
    });
    expect(push).not.toHaveBeenCalled();
    await flushPromises();
    expect(alertMock).toHaveBeenCalledWith('INBOX.NOTIFICATION_MODAL.ARCHIVED');

    await wrapper
      .get('[data-test="archive-all-notifications"]')
      .trigger('click');
    await flushPromises();
    expect(dispatch).toHaveBeenCalledWith('notifications/readAll');
    expect(alertMock).toHaveBeenLastCalledWith(
      'INBOX.NOTIFICATION_MODAL.ARCHIVED_ALL'
    );
  });

  it('does not report success when archiving one notification fails', async () => {
    const wrapper = mountPanel();
    await wrapper.vm.open();
    dispatch.mockImplementation(action =>
      Promise.resolve(action === 'notifications/archive' ? false : undefined)
    );

    await wrapper.get('[data-test="archive-notification"]').trigger('click');
    await flushPromises();

    expect(alertMock).not.toHaveBeenCalled();
  });

  it('does not report success when archiving all fails', async () => {
    const wrapper = mountPanel();
    await wrapper.vm.open();
    dispatch.mockImplementation(action =>
      action === 'notifications/readAll'
        ? Promise.reject(new Error('network'))
        : dispatchSucceeds(action)
    );

    await wrapper
      .get('[data-test="archive-all-notifications"]')
      .trigger('click');
    await flushPromises();

    expect(alertMock).not.toHaveBeenCalledWith(
      'INBOX.NOTIFICATION_MODAL.ARCHIVED_ALL'
    );
  });

  it('disables archive all when nothing is unread', async () => {
    getters.meta.value = { count: 1, unreadCount: 0 };
    getters.records.value = () => [
      unreadNotification({ readAt: 1_777_777_800 }),
    ];
    const wrapper = mountPanel();
    await wrapper.vm.open();

    expect(
      wrapper
        .get('[data-test="archive-all-notifications"]')
        .attributes('disabled')
    ).toBeDefined();
  });

  it('archives the notification and opens its conversation on click', async () => {
    const wrapper = mountPanel();
    await wrapper.vm.open();
    dispatch.mockClear();

    await wrapper.get('[data-test="notification-item"]').trigger('click');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('notifications/archive', {
      id: 7,
      unreadCount: 1,
    });
    expect(push).toHaveBeenCalledWith(
      '/app/accounts/1/inbox/5/conversations/21'
    );
    expect(wrapper.find('.notification-side-panel').exists()).toBe(false);
  });

  // The notifications API attaches the thread display id when the
  // conversation belongs to a communication thread (G track).
  it('opens a thread notification in the unified thread view', async () => {
    getters.records.value = () => [
      unreadNotification({ communicationThreadId: 88 }),
    ];
    const wrapper = mountPanel();
    await wrapper.vm.open();

    await wrapper.get('[data-test="notification-item"]').trigger('click');
    await flushPromises();

    expect(push).toHaveBeenCalledTimes(1);
    const [target] = push.mock.calls[0];
    expect(target.split('?')[0]).toBe(
      '/app/accounts/1/communication_threads/88'
    );
  });

  it.each([
    ['Crm::Task', 'task_assignment', 'crm_tasks_index', 'taskId'],
    ['Crm::Deal', 'deal_assignment', 'crm_deals_index', 'dealId'],
    [
      'Scheduling::Appointment',
      'appointment_assignment',
      'scheduling_calendar',
      'appointmentId',
    ],
  ])(
    'opens the %s page of the notification, not a conversation',
    async (primaryActorType, notificationType, routeName, queryKey) => {
      // These actors have no push payload: primary_actor is { id, meta: {} }.
      getters.records.value = () => [
        unreadNotification({
          notificationType,
          primaryActorType,
          primaryActorId: 42,
          primaryActor: { id: 42, meta: {} },
        }),
      ];
      const wrapper = mountPanel();
      await wrapper.vm.open();

      await wrapper.get('[data-test="notification-item"]').trigger('click');
      await flushPromises();

      expect(push).toHaveBeenCalledTimes(1);
      expect(push).toHaveBeenCalledWith({
        name: routeName,
        params: { accountId: 1 },
        query: { [queryKey]: '42' },
      });
      expect(dispatch).toHaveBeenCalledWith('notifications/archive', {
        id: 7,
        unreadCount: 1,
      });
    }
  );

  it('keeps a notification without a page of its own unread and in place', async () => {
    getters.records.value = () => [
      unreadNotification({
        primaryActorType: 'Captain::Document',
        primaryActorId: 42,
        primaryActor: { id: 42, meta: {} },
      }),
    ];
    const wrapper = mountPanel();
    await wrapper.vm.open();
    dispatch.mockClear();

    const item = wrapper.get('[data-test="notification-item"]');
    expect(item.classes()).toContain('cursor-default');
    await item.trigger('click');
    await flushPromises();

    expect(push).not.toHaveBeenCalled();
    expect(dispatch).not.toHaveBeenCalledWith(
      'notifications/archive',
      expect.anything()
    );
    expect(wrapper.find('.notification-side-panel').exists()).toBe(true);
  });

  it('opens an already archived notification without archiving it again', async () => {
    getters.records.value = () => [
      unreadNotification({ readAt: 1_777_777_800 }),
    ];
    const wrapper = mountPanel();
    await wrapper.vm.open();
    await wrapper.get('[data-test="notification-tab-all"]').trigger('click');
    await flushPromises();
    dispatch.mockClear();

    await wrapper.get('[data-test="notification-item"]').trigger('click');
    await flushPromises();

    expect(dispatch).not.toHaveBeenCalledWith(
      'notifications/archive',
      expect.anything()
    );
    expect(push).toHaveBeenCalledWith(
      '/app/accounts/1/inbox/5/conversations/21'
    );
  });

  it('loads the next page after the last notification the server returned', async () => {
    const firstPage = serverPage(15, { count: 20 });
    dispatch.mockImplementation(action =>
      action === 'notifications/index'
        ? Promise.resolve(firstPage)
        : dispatchSucceeds(action)
    );
    const wrapper = mountPanel();
    await wrapper.vm.open();
    await flushPromises();
    dispatch.mockClear();

    await wrapper.get('[data-test="notification-load-more"]').trigger('click');
    await flushPromises();

    expect(dispatch).not.toHaveBeenCalledWith('notifications/clear');
    expect(dispatch).toHaveBeenCalledWith('notifications/index', {
      sortOrder: 'desc',
      status: '',
      cursor: { id: 86, lastActivityAt: 1_777_776_986 },
    });
  });

  it('hides "Show more" once a page comes back short or the tab fits one page', async () => {
    let page = serverPage(15, { count: 15 });
    dispatch.mockImplementation(action =>
      action === 'notifications/index'
        ? Promise.resolve(page)
        : dispatchSucceeds(action)
    );
    const wrapper = mountPanel();
    await wrapper.vm.open();
    await flushPromises();
    expect(wrapper.find('[data-test="notification-load-more"]').exists()).toBe(
      false
    );

    page = serverPage(15, { count: 40 });
    await wrapper.get('[data-test="notification-tab-all"]').trigger('click');
    await flushPromises();
    expect(wrapper.find('[data-test="notification-load-more"]').exists()).toBe(
      true
    );

    page = serverPage(3, { count: 40, firstId: 85 });
    await wrapper.get('[data-test="notification-load-more"]').trigger('click');
    await flushPromises();
    expect(wrapper.find('[data-test="notification-load-more"]').exists()).toBe(
      false
    );
  });

  it('ignores a page that arrives after the employee switched tabs', async () => {
    let resolveNewTab;
    dispatch.mockImplementation(action => {
      if (action !== 'notifications/index') return dispatchSucceeds(action);
      if (!resolveNewTab) {
        return new Promise(resolve => {
          resolveNewTab = resolve;
        });
      }
      return Promise.resolve(serverPage(2, { count: 2 }));
    });
    const wrapper = mountPanel();
    wrapper.vm.open();
    await flushPromises();

    await wrapper.get('[data-test="notification-tab-all"]').trigger('click');
    await flushPromises();
    resolveNewTab(serverPage(15, { count: 30 }));
    await flushPromises();

    expect(wrapper.find('[data-test="notification-load-more"]').exists()).toBe(
      false
    );
  });

  it('closes with Escape', async () => {
    const wrapper = mountPanel();
    await wrapper.vm.open();

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    await wrapper.vm.$nextTick();

    expect(wrapper.find('.notification-side-panel').exists()).toBe(false);
  });
});
