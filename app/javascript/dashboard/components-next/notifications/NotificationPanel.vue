<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';

import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { conversationUrl, frontendURL } from 'dashboard/helper/URLHelper';
import { shortTimestamp } from 'shared/helpers/timeHelper';

import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TeleportWithDirection from 'dashboard/components-next/TeleportWithDirection.vue';

const props = defineProps({
  sidebarOffset: {
    type: Number,
    default: 44,
  },
});

const { t } = useI18n();
const router = useRouter();
const store = useStore();

// Page size of the notifications API (NotificationFinder::RESULTS_PER_PAGE).
const PER_PAGE = 15;

// Maps a tab to the `includes` filter of the notifications API.
const TAB_STATUS = {
  all: 'read',
  archive: 'archived',
  new: '',
};

// Pages opened by notifications that are not about a conversation; the same
// links as in the notification emails.
const ACTOR_ROUTES = {
  'Crm::Task': { name: 'crm_tasks_index', queryKey: 'taskId' },
  'Crm::Deal': { name: 'crm_deals_index', queryKey: 'dealId' },
  'Scheduling::Appointment': {
    name: 'scheduling_calendar',
    queryKey: 'appointmentId',
  },
};

const isOpen = ref(false);
const activeTab = ref('new');
// The last notification the server returned: the next page starts right
// after it, so notifications archived or added meanwhile never shift it.
const cursor = ref(null);
// The last page was full, so the server may have more.
const hasMore = ref(false);
let latestRequest = 0;

const accountId = useMapGetter('getCurrentAccountId');
const meta = useMapGetter('notifications/getMeta');
const recordsGetter = useMapGetter('notifications/getFilteredNotificationsV4');
const uiFlags = useMapGetter('notifications/getUIFlags');

const tabs = computed(() => [
  { key: 'new', label: t('INBOX.NOTIFICATION_MODAL.TABS.NEW') },
  { key: 'archive', label: t('INBOX.NOTIFICATION_MODAL.TABS.ARCHIVE') },
  { key: 'all', label: t('INBOX.NOTIFICATION_MODAL.TABS.ALL') },
]);

const notifications = computed(() => {
  const records = recordsGetter.value({ sortOrder: 'desc' });
  if (activeTab.value === 'new') {
    return records.filter(notification => !notification.readAt);
  }
  if (activeTab.value === 'archive') {
    return records.filter(notification => notification.readAt);
  }
  return records;
});

const hasUnreadNotifications = computed(() => {
  if (Number(meta.value.unreadCount) > 0) return true;
  return notifications.value.some(notification => !notification.readAt);
});

const fetchNotifications = async ({ reset = true } = {}) => {
  latestRequest += 1;
  const request = latestRequest;
  if (reset) {
    cursor.value = null;
    hasMore.value = false;
    await store.dispatch('notifications/clear');
  }

  const isFirstPage = !cursor.value;
  const query = { sortOrder: 'desc', status: TAB_STATUS[activeTab.value] };
  const response = await store.dispatch(
    'notifications/index',
    isFirstPage ? { page: 1, ...query } : { ...query, cursor: cursor.value }
  );
  // A newer request (another tab, a reopened panel) owns the paging state.
  if (request !== latestRequest || !response) return;

  const { payload = [], meta: pageMeta = {} } = response;
  const last = payload[payload.length - 1];
  if (last) {
    cursor.value = { id: last.id, lastActivityAt: last.last_activity_at };
  }
  // The first page also knows the tab total, which rules out an empty page
  // when the tab holds exactly one full page.
  hasMore.value =
    payload.length >= PER_PAGE &&
    !(isFirstPage && Number(pageMeta.count) <= payload.length);
};

const changeTab = async tab => {
  if (activeTab.value === tab) return;
  activeTab.value = tab;
  await fetchNotifications();
};

const loadMore = () => fetchNotifications({ reset: false });

// Archiving marks only this notification as read; other notifications of the
// same conversation stay in "New".
const archive = async notification => {
  if (notification.readAt) return false;

  const archived = await store.dispatch('notifications/archive', {
    id: notification.id,
    unreadCount: Number(meta.value.unreadCount || 0),
  });
  if (archived) useAlert(t('INBOX.NOTIFICATION_MODAL.ARCHIVED'));
  return archived;
};

const archiveNotification = async notification => {
  const archived = await archive(notification);
  // The New tab must not look empty while the server has more.
  if (
    archived &&
    activeTab.value === 'new' &&
    !notifications.value.length &&
    hasMore.value
  ) {
    await loadMore();
  }
};

const archiveAll = async () => {
  try {
    await store.dispatch('notifications/readAll');
  } catch {
    // The store keeps the unread state when the request fails.
    return;
  }
  useAlert(t('INBOX.NOTIFICATION_MODAL.ARCHIVED_ALL'));
  // Nothing is unread any more, and the archive now also holds notifications
  // above the loaded pages.
  if (activeTab.value === 'new') hasMore.value = false;
  if (activeTab.value === 'archive') await fetchNotifications();
};

const close = () => {
  isOpen.value = false;
};

const conversationRoute = notification => {
  // The conversation payload carries the display id used in URLs.
  const conversationId = notification.primaryActor?.id;
  if (!conversationId) return null;

  const inboxId =
    notification.primaryActor?.inboxId || notification.primaryActor?.inbox_id;
  return frontendURL(
    conversationUrl({
      accountId: accountId.value,
      activeInbox: inboxId,
      id: conversationId,
    })
  );
};

const notificationRoute = notification => {
  if (notification.primaryActorType === 'Conversation') {
    return conversationRoute(notification);
  }

  const actorRoute = ACTOR_ROUTES[notification.primaryActorType];
  const actorId = notification.primaryActorId;
  if (!actorRoute || !actorId) return null;

  return {
    name: actorRoute.name,
    params: { accountId: accountId.value },
    query: { [actorRoute.queryKey]: String(actorId) },
  };
};

// Notifications without a page of their own stay unread: the employee can
// still archive them with the button.
const openNotification = async notification => {
  const target = notificationRoute(notification);
  if (!target) return;

  await archive(notification);
  close();
  await router.push(target);
};

const notificationTitle = notification =>
  notification.pushMessageTitle ||
  notification.primaryActor?.meta?.sender?.name ||
  t('INBOX.NOTIFICATION_MODAL.NOTIFICATION');

const notificationBody = notification =>
  notification.pushMessageBody || notificationTitle(notification);

const notificationTime = notification => {
  const timestamp = notification.lastActivityAt || notification.createdAt;
  return timestamp ? shortTimestamp(timestamp) : '';
};

const open = async () => {
  activeTab.value = 'new';
  isOpen.value = true;
  await fetchNotifications();
};

const toggle = () => (isOpen.value ? close() : open());

useEventListener(document, 'keydown', event => {
  if (isOpen.value && event.key === 'Escape') close();
});

defineExpose({ close, open, toggle });
</script>

<template>
  <TeleportWithDirection to="body">
    <OnClickOutside
      v-if="isOpen"
      :options="{ ignore: ['[data-notification-panel-trigger]'] }"
      @trigger="close"
    >
      <aside
        role="dialog"
        :aria-label="t('INBOX.NOTIFICATION_MODAL.TITLE')"
        class="notification-side-panel fixed bottom-1.5 z-[60] flex h-[calc(100vh-1.5rem)] max-h-[38rem] w-[26rem] flex-col overflow-hidden rounded-2xl border border-n-weak bg-n-surface-1 shadow-2xl"
        :style="{
          '--notification-panel-offset': `${props.sidebarOffset}px`,
          maxWidth: `calc(100vw - ${props.sidebarOffset + 8}px)`,
        }"
      >
        <header class="flex items-center justify-between gap-4 px-5 pb-3 pt-5">
          <h2 class="mb-0 text-lg font-semibold text-n-slate-12">
            {{ t('INBOX.NOTIFICATION_MODAL.TITLE') }}
          </h2>
          <div class="flex items-center">
            <Button
              data-test="archive-all-notifications"
              color="slate"
              variant="ghost"
              size="sm"
              :disabled="!hasUnreadNotifications"
              :is-loading="uiFlags.isUpdating"
              :label="t('INBOX.NOTIFICATION_MODAL.ARCHIVE_ALL')"
              @click="archiveAll"
            />
          </div>
        </header>

        <div
          class="flex items-end gap-6 border-b border-n-weak px-5"
          role="tablist"
        >
          <button
            v-for="tab in tabs"
            :key="tab.key"
            type="button"
            role="tab"
            :data-test="`notification-tab-${tab.key}`"
            class="relative h-11 text-sm font-medium transition-colors"
            :class="
              activeTab === tab.key
                ? 'text-n-brand'
                : 'text-n-slate-10 hover:text-n-slate-12'
            "
            :aria-selected="activeTab === tab.key"
            @click="changeTab(tab.key)"
          >
            {{ tab.label }}
            <span
              v-if="activeTab === tab.key"
              class="absolute inset-x-0 bottom-0 h-0.5 rounded-full bg-n-brand"
            />
          </button>
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto px-5">
          <div
            v-if="uiFlags.isFetching && !notifications.length"
            class="grid h-64 place-items-center"
          >
            <Spinner class="text-n-brand" />
          </div>

          <div
            v-else-if="!notifications.length"
            class="grid h-64 place-items-center text-center"
            data-test="notification-panel-empty"
          >
            <div class="flex flex-col items-center gap-2 px-6">
              <span class="i-lucide-bell-off size-7 text-n-slate-9" />
              <p class="mb-0 text-sm text-n-slate-10">
                {{ t('INBOX.NOTIFICATION_MODAL.EMPTY') }}
              </p>
            </div>
          </div>

          <ul v-else class="m-0 flex list-none flex-col divide-y divide-n-weak">
            <li
              v-for="notification in notifications"
              :key="notification.id"
              class="group flex items-start gap-3 py-4"
              :class="
                notificationRoute(notification)
                  ? 'cursor-pointer'
                  : 'cursor-default'
              "
              data-test="notification-item"
              @click="openNotification(notification)"
            >
              <span
                class="grid size-10 shrink-0 place-items-center rounded-full"
                :class="
                  notification.readAt
                    ? 'bg-n-alpha-2 text-n-slate-10'
                    : 'bg-n-iris-3 text-n-iris-11'
                "
              >
                <span class="i-lucide-bell size-4" />
              </span>

              <div class="min-w-0 flex-1">
                <div class="flex items-start justify-between gap-3">
                  <p
                    class="mb-0 line-clamp-2 text-sm"
                    :class="
                      notification.readAt
                        ? 'font-medium text-n-slate-11'
                        : 'font-semibold text-n-slate-12'
                    "
                  >
                    {{ notificationTitle(notification) }}
                  </p>
                  <span class="shrink-0 text-xs text-n-slate-9">
                    {{ notificationTime(notification) }}
                  </span>
                </div>
                <p class="mb-0 mt-1 line-clamp-2 text-sm text-n-slate-10">
                  {{ notificationBody(notification) }}
                </p>
                <Button
                  v-if="!notification.readAt"
                  data-test="archive-notification"
                  class="mt-2"
                  color="slate"
                  variant="ghost"
                  size="sm"
                  :label="t('INBOX.NOTIFICATION_MODAL.ARCHIVE')"
                  @click.stop="archiveNotification(notification)"
                />
              </div>
            </li>
          </ul>

          <Button
            v-if="hasMore"
            class="my-3 w-full"
            color="slate"
            variant="ghost"
            data-test="notification-load-more"
            :is-loading="uiFlags.isFetching"
            :label="t('INBOX.NOTIFICATION_MODAL.LOAD_MORE')"
            @click="loadMore"
          />
        </div>
      </aside>
    </OnClickOutside>
  </TeleportWithDirection>
</template>

<style scoped>
.notification-side-panel {
  inset-inline-start: var(--notification-panel-offset);
}
</style>
