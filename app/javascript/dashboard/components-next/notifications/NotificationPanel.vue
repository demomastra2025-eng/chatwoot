<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { OnClickOutside } from '@vueuse/components';

import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { conversationUrl, frontendURL } from 'dashboard/helper/URLHelper';
import { getNotificationCommunicationThreadId } from 'dashboard/helper/communicationThreadHelper';
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

const isOpen = ref(false);
const activeTab = ref('new');
const page = ref(1);

const accountId = useMapGetter('getCurrentAccountId');
const meta = useMapGetter('notifications/getMeta');
const recordsGetter = useMapGetter('notifications/getFilteredNotificationsV4');
const uiFlags = useMapGetter('notifications/getUIFlags');

const tabs = computed(() => [
  { key: 'new', label: t('INBOX.NOTIFICATION_MODAL.TABS.NEW') },
  { key: 'archive', label: t('INBOX.NOTIFICATION_MODAL.TABS.ARCHIVE') },
  { key: 'all', label: t('INBOX.NOTIFICATION_MODAL.TABS.ALL') },
]);

const tabStatus = computed(() => ({
  all: 'read',
  archive: 'archived',
  new: '',
}));

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

const canLoadMore = computed(
  () => notifications.value.length < Number(meta.value.count || 0)
);

const fetchNotifications = async ({ reset = true } = {}) => {
  if (reset) {
    page.value = 1;
    await store.dispatch('notifications/clear');
  }

  await store.dispatch('notifications/index', {
    page: page.value,
    sortOrder: 'desc',
    status: tabStatus.value[activeTab.value],
  });
};

const changeTab = async tab => {
  if (activeTab.value === tab) return;
  activeTab.value = tab;
  await fetchNotifications();
};

const loadMore = async () => {
  page.value += 1;
  await fetchNotifications({ reset: false });
};

const archiveNotification = async notification => {
  if (notification.readAt) return;

  await store.dispatch('notifications/archive', {
    id: notification.id,
    unreadCount: Number(meta.value.unreadCount || 0),
  });
  useAlert(t('INBOX.NOTIFICATION_MODAL.ARCHIVED'));
};

const archiveAll = async () => {
  await store.dispatch('notifications/readAll');
  useAlert(t('INBOX.NOTIFICATION_MODAL.ARCHIVED_ALL'));
};

const close = () => {
  isOpen.value = false;
};

const openNotification = async notification => {
  await archiveNotification(notification);

  const conversationId = notification.primaryActor?.id;
  const communicationThreadId =
    getNotificationCommunicationThreadId(notification);
  const inboxId =
    notification.primaryActor?.inboxId || notification.primaryActor?.inbox_id;
  if (!conversationId && !communicationThreadId) return;

  close();
  await router.push(
    frontendURL(
      conversationUrl({
        accountId: accountId.value,
        activeInbox: inboxId,
        id: communicationThreadId || conversationId,
        communicationThread: Boolean(communicationThreadId),
      })
    )
  );
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
          maxWidth: `calc(100vw - ${props.sidebarOffset}px)`,
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
              class="group flex cursor-pointer items-start gap-3 py-4"
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
            v-if="canLoadMore"
            class="my-3 w-full"
            color="slate"
            variant="ghost"
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
