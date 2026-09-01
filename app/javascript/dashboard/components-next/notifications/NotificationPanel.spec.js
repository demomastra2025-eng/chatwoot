import { flushPromises, mount } from '@vue/test-utils';
/* eslint-disable vue/one-component-per-file */
import { defineComponent, h } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const { dispatch, getters, push } = vi.hoisted(() => ({
  dispatch: vi.fn(() => Promise.resolve()),
  push: vi.fn(() => Promise.resolve()),
  getters: {
    accountId: { value: 1 },
    meta: { value: { count: 1, unreadCount: 1 } },
    records: {
      value: () => [
        {
          id: 7,
          lastActivityAt: 1_777_777_777,
          primaryActor: { id: 21, inboxId: 5 },
          primaryActorId: 21,
          primaryActorType: 'Conversation',
          pushMessageBody: 'Notification body',
          pushMessageTitle: 'Notification title',
          readAt: null,
        },
      ],
    },
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
  useAlert: vi.fn(),
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push }),
}));

import NotificationPanel from './NotificationPanel.vue';

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
      mocks: { $t: key => key },
      stubs: {
        Button: ButtonStub,
        OnClickOutside: { template: '<div><slot /></div>' },
        Spinner: true,
        TeleportWithDirection: { template: '<div><slot /></div>' },
      },
    },
  });

describe('NotificationPanel', () => {
  beforeEach(() => {
    dispatch.mockClear();
    push.mockClear();
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
    expect(
      wrapper.get('.notification-side-panel').attributes('style')
    ).toContain('--notification-panel-offset: 44px');
    const panel = wrapper.get('.notification-side-panel');
    expect(panel.classes()).toContain('w-[26rem]');
    expect(panel.classes()).toContain('max-h-[38rem]');
    expect(panel.classes()).toContain('rounded-2xl');
    expect(panel.classes()).toContain('bottom-1.5');
    expect(panel.classes()).not.toContain('top-1/2');
    expect(wrapper.find('[aria-label="DIALOG.BUTTONS.CLOSE"]').exists()).toBe(
      false
    );

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

  it('loads archived notifications in the archive tab', async () => {
    const wrapper = mountPanel();
    await wrapper.vm.open();
    dispatch.mockClear();

    await wrapper
      .get('[data-test="notification-tab-archive"]')
      .trigger('click');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('notifications/index', {
      page: 1,
      sortOrder: 'desc',
      status: 'archived',
    });
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

    await wrapper
      .get('[data-test="archive-all-notifications"]')
      .trigger('click');
    expect(dispatch).toHaveBeenCalledWith('notifications/readAll');
  });

  it('opens a communication thread when the notification provides its id', async () => {
    getters.records.value = () => [
      {
        id: 8,
        communicationThreadId: 77,
        primaryActor: { id: 21, inboxId: 5 },
        pushMessageTitle: 'Thread notification',
        readAt: null,
      },
    ];
    const wrapper = mountPanel();
    await wrapper.vm.open();

    await wrapper.get('li').trigger('click');
    await flushPromises();

    expect(push).toHaveBeenCalledWith(
      '/app/accounts/1/communication_threads/77'
    );
  });
});
