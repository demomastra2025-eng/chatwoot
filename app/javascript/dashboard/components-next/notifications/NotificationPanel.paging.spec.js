// The panel against the real notifications store and a fake server with the
// NotificationFinder rules: 15 per page, newest activity first, and a page
// that continues right after the cursor notification.
import { flushPromises, mount } from '@vue/test-utils';
/* eslint-disable vue/one-component-per-file */
import { computed, defineComponent, h } from 'vue';
import { createStore } from 'vuex';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const { server, holder } = vi.hoisted(() => ({
  server: { rows: [] },
  holder: { store: null },
}));

const PER_PAGE = 15;
const inTab = (row, status) => {
  if (status === 'archived') return Boolean(row.read_at);
  if (status === 'read') return true;
  return !row.read_at;
};
const newestFirst = (a, b) =>
  b.last_activity_at - a.last_activity_at || b.id - a.id;
const unreadCount = () => server.rows.filter(row => !row.read_at).length;

const afterCursor = (rows, cursor) => {
  if (!cursor) return rows;
  const found = server.rows.find(row => row.id === cursor.id);
  if (found) {
    return rows.filter(row => newestFirst(found, row) < 0);
  }
  // A deleted cursor: its whole second is listed again.
  return rows.filter(row => row.last_activity_at < cursor.lastActivityAt + 1);
};

vi.mock('dashboard/api/notifications', () => ({
  default: {
    get: vi.fn(({ page = 1, status, cursor }) => {
      const tabRows = server.rows
        .filter(row => inTab(row, status))
        .sort(newestFirst);
      const payload = afterCursor(tabRows, cursor)
        .slice((page - 1) * PER_PAGE, page * PER_PAGE)
        .map(row => ({ ...row }));
      return Promise.resolve({
        data: {
          data: {
            payload,
            meta: {
              count: tabRows.length,
              current_page: page,
              unread_count: unreadCount(),
            },
          },
        },
      });
    }),
    archive: vi.fn(id => {
      server.rows.find(row => row.id === id).read_at = 1_800_000_000;
      return Promise.resolve({});
    }),
  },
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: key => computed(() => holder.store.getters[key]),
  useStore: () => holder.store,
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('vue-router', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

import notifications from 'dashboard/store/modules/notifications';
import NotificationPanel from './NotificationPanel.vue';

const ButtonStub = defineComponent({
  inheritAttrs: false,
  props: { disabled: Boolean, label: { type: String, default: '' } },
  emits: ['click'],
  setup(props, { attrs, emit }) {
    return () =>
      h(
        'button',
        { ...attrs, disabled: props.disabled, onClick: e => emit('click', e) },
        props.label
      );
  },
});

const row = (id, overrides = {}) => ({
  id,
  notification_type: 'conversation_assignment',
  primary_actor_type: 'Conversation',
  primary_actor_id: 1000 + id,
  primary_actor: { id: 1000 + id, inbox_id: 5, meta: {} },
  push_message_title: `title-${id}`,
  push_message_body: `body-${id}`,
  read_at: null,
  last_activity_at: 1_700_000_000 + id,
  created_at: 1_700_000_000 + id,
  ...overrides,
});

const mountPanel = () => {
  holder.store = createStore({
    modules: {
      notifications: {
        ...notifications,
        state: () => ({
          meta: { count: 0, currentPage: 1, unreadCount: 0 },
          records: {},
          uiFlags: {
            isFetching: false,
            isUpdating: false,
            isAllNotificationsLoaded: false,
          },
          notificationFilters: {},
        }),
      },
    },
    getters: { getCurrentAccountId: () => 1 },
  });
  return mount(NotificationPanel, {
    global: {
      stubs: {
        Button: ButtonStub,
        OnClickOutside: { template: '<div><slot /></div>' },
        Spinner: true,
        TeleportWithDirection: { template: '<div><slot /></div>' },
      },
    },
  });
};

const shownIds = wrapper =>
  wrapper
    .findAll('[data-test="notification-item"]')
    .map(item => Number(item.text().match(/body-(\d+)/)[1]));
const loadMoreButton = wrapper =>
  wrapper.find('[data-test="notification-load-more"]');
const serverIds = status =>
  server.rows
    .filter(item => inTab(item, status))
    .sort(newestFirst)
    .map(item => item.id);

const archiveFirstShown = async wrapper => {
  await wrapper.get('[data-test="archive-notification"]').trigger('click');
  await flushPromises();
};

describe('NotificationPanel paging', () => {
  beforeEach(() => {
    server.rows = [];
  });

  it('shows every unread notification after archiving and "Show more"', async () => {
    server.rows = Array.from({ length: 20 }, (_, index) => row(index + 1));
    const wrapper = mountPanel();
    await wrapper.vm.open();
    await flushPromises();
    expect(shownIds(wrapper)).toEqual(serverIds('').slice(0, 15));

    await archiveFirstShown(wrapper);
    await archiveFirstShown(wrapper);
    await archiveFirstShown(wrapper);
    await loadMoreButton(wrapper).trigger('click');
    await flushPromises();

    expect(shownIds(wrapper)).toEqual(serverIds(''));
    expect(shownIds(wrapper)).toHaveLength(17);
    expect(loadMoreButton(wrapper).exists()).toBe(false);
  });

  it('offers no "Show more" after archiving the only notification', async () => {
    server.rows = [row(1)];
    const wrapper = mountPanel();
    await wrapper.vm.open();
    await flushPromises();

    await archiveFirstShown(wrapper);

    expect(loadMoreButton(wrapper).exists()).toBe(false);
    expect(
      wrapper.find('[data-test="notification-panel-empty"]').exists()
    ).toBe(true);
  });

  it('keeps "Show more" on the All tab when a notification arrives live', async () => {
    server.rows = Array.from({ length: 40 }, (_, index) =>
      row(index + 1, { read_at: index < 37 ? 1_750_000_000 : null })
    );
    const wrapper = mountPanel();
    await wrapper.vm.open();
    await wrapper.get('[data-test="notification-tab-all"]').trigger('click');
    await flushPromises();
    expect(loadMoreButton(wrapper).exists()).toBe(true);

    // ActionCableListener#notification_created sends the unread counts.
    const fresh = row(41);
    server.rows.push(fresh);
    await holder.store.dispatch('notifications/addNotification', {
      notification: fresh,
      unread_count: 4,
      count: 4,
    });
    await flushPromises();
    expect(shownIds(wrapper)).toHaveLength(16);
    expect(loadMoreButton(wrapper).exists()).toBe(true);

    await loadMoreButton(wrapper).trigger('click');
    await flushPromises();
    await loadMoreButton(wrapper).trigger('click');
    await flushPromises();
    expect(shownIds(wrapper)).toEqual(serverIds('read'));
    expect(loadMoreButton(wrapper).exists()).toBe(false);
  });

  it('pages the archive tab to its end', async () => {
    server.rows = Array.from({ length: 31 }, (_, index) =>
      row(index + 1, { read_at: 1_750_000_000 })
    );
    const wrapper = mountPanel();
    await wrapper.vm.open();
    await wrapper
      .get('[data-test="notification-tab-archive"]')
      .trigger('click');
    await flushPromises();

    await loadMoreButton(wrapper).trigger('click');
    await flushPromises();
    await loadMoreButton(wrapper).trigger('click');
    await flushPromises();

    expect(shownIds(wrapper)).toEqual(serverIds('archived'));
    expect(loadMoreButton(wrapper).exists()).toBe(false);
  });

  it('brings in the next page when every loaded notification was archived', async () => {
    server.rows = Array.from({ length: 18 }, (_, index) => row(index + 1));
    const wrapper = mountPanel();
    await wrapper.vm.open();
    await flushPromises();

    for (let archived = 0; archived < 15; archived += 1) {
      // eslint-disable-next-line no-await-in-loop
      await archiveFirstShown(wrapper);
    }

    expect(shownIds(wrapper)).toEqual([3, 2, 1]);
    expect(loadMoreButton(wrapper).exists()).toBe(false);
  });

  it('skips nothing when the cursor notification was replaced meanwhile', async () => {
    server.rows = Array.from({ length: 20 }, (_, index) => row(index + 1));
    const wrapper = mountPanel();
    await wrapper.vm.open();
    await flushPromises();

    // A newer notification of the same conversation replaces the last loaded
    // one (Notification::RemoveDuplicateNotificationJob).
    server.rows = server.rows.filter(item => item.id !== 6);
    await holder.store.dispatch('notifications/deleteNotification', {
      notification: { id: 6 },
      unread_count: 19,
      count: 19,
    });
    await loadMoreButton(wrapper).trigger('click');
    await flushPromises();

    expect(shownIds(wrapper)).toEqual(serverIds(''));
  });
});
