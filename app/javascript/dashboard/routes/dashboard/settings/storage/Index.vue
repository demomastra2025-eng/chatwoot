<script setup>
import { ref, computed, onMounted, onBeforeUnmount, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import StorageAPI from 'dashboard/api/storage';
import { useAccount } from 'dashboard/composables/useAccount';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import { formatStorageBytes, formatStorageDate } from './storageFormatters';

const { t, locale } = useI18n();
const { accountId } = useAccount();

const activeTab = ref('overview');
const isLoading = ref(true);
const isRefreshing = ref(false);
const storageData = ref(null);
const heavyFiles = ref([]);
const isLoadingFiles = ref(false);
const recordingsPending = ref(false);
const recordingsRefreshStatus = ref('idle');
const heavyFilesError = ref(false);
let heavyFilesRequestId = 0;
let storageRequestId = 0;
let trashRequestId = 0;
let previewRequestId = 0;
let pageActive = true;
let storagePollTimer;

const selectedFileType = ref('all');
const selectedInboxId = ref('');
const selectedConversationId = ref('');
const selectedDateFrom = ref('');
const selectedDateTo = ref('');
const storageAlertClock = ref(Date.now());
const storageAlertDismissal = ref(null);
let storageAlertTimer;

// Cleaner state
const cleanerFileType = ref('all');
const cleanerMonths = ref(6);
const cleanerInboxId = ref('');
const isPreviewing = ref(false);
const previewData = ref(null);
const isMovingToTrash = ref(false);
watch([cleanerFileType, cleanerMonths, cleanerInboxId], () => {
  previewRequestId += 1;
  previewData.value = null;
  isPreviewing.value = false;
});

// Trash state
const trashData = ref({ total_count: 0, total_bytes: 0, items: [] });
const isLoadingTrash = ref(false);
const isRestoring = ref(false);
const isPurging = ref(false);

const unitLabels = computed(() => ({
  B: t('STORAGE.UNITS.B'),
  KB: t('STORAGE.UNITS.KB'),
  MB: t('STORAGE.UNITS.MB'),
  GB: t('STORAGE.UNITS.GB'),
  TB: t('STORAGE.UNITS.TB'),
}));

const formatBytes = (bytes, decimals = 2) =>
  formatStorageBytes(bytes, {
    locale: locale.value,
    unitLabels: unitLabels.value,
    decimals,
  });

const formatDate = dateStr => formatStorageDate(dateStr, locale.value);

const fetchHeavyFiles = async () => {
  heavyFilesRequestId += 1;
  const requestId = heavyFilesRequestId;
  const requestAccount = accountId.value;
  const current = () =>
    pageActive &&
    requestId === heavyFilesRequestId &&
    requestAccount === accountId.value;
  try {
    isLoadingFiles.value = true;
    heavyFilesError.value = false;
    const params = { file_type: selectedFileType.value, limit: 50 };
    if (selectedInboxId.value) params.inbox_id = selectedInboxId.value;
    if (selectedConversationId.value)
      params.conversation_id = selectedConversationId.value;
    if (selectedDateFrom.value) params.date_from = selectedDateFrom.value;
    if (selectedDateTo.value) params.date_to = selectedDateTo.value;
    const response = await StorageAPI.getHeavyFiles(params);
    if (!current()) return;
    heavyFiles.value = response.data.files || [];
    recordingsPending.value = response.data.recordings_pending === true;
    recordingsRefreshStatus.value =
      response.data.recordings_refresh_status || 'pending';
  } catch (error) {
    if (!current()) return;
    heavyFiles.value = [];
    heavyFilesError.value = true;
    recordingsPending.value = false;
    useAlert(error?.response?.data?.message || t('STORAGE.HEAVY_FILES_ERROR'));
  } finally {
    if (current()) isLoadingFiles.value = false;
  }
};

const fetchStorageInfo = async () => {
  storageRequestId += 1;
  const requestId = storageRequestId;
  const requestAccount = accountId.value;
  const current = () =>
    pageActive &&
    requestId === storageRequestId &&
    requestAccount === accountId.value;
  try {
    isLoading.value = storageData.value === null;
    const response = await StorageAPI.getStorage();
    if (!current()) return;
    storageData.value = response.data.storage;
  } catch (error) {
    if (!current()) return;
    useAlert(error?.response?.data?.message || t('STORAGE.FETCH_ERROR'));
  } finally {
    if (current()) isLoading.value = false;
  }
};

const fetchTrash = async () => {
  trashRequestId += 1;
  const requestId = trashRequestId;
  const requestAccount = accountId.value;
  const current = () =>
    pageActive &&
    requestId === trashRequestId &&
    requestAccount === accountId.value;
  try {
    isLoadingTrash.value = true;
    const response = await StorageAPI.getTrash();
    if (!current()) return;
    trashData.value = response.data || {
      total_count: 0,
      total_bytes: 0,
      items: [],
    };
  } catch (error) {
    if (!current()) return;
    useAlert(error?.response?.data?.message || t('STORAGE.FETCH_ERROR'));
  } finally {
    if (current()) isLoadingTrash.value = false;
  }
};

const refreshStorage = async () => {
  storageRequestId += 1;
  const requestId = storageRequestId;
  const requestAccount = accountId.value;
  const current = () =>
    pageActive &&
    requestId === storageRequestId &&
    requestAccount === accountId.value;
  try {
    isRefreshing.value = true;
    const response = await StorageAPI.refresh();
    if (!current()) return;
    storageData.value = response.data.storage;
    const status = response.data.refresh_status;
    const alertKey = {
      queued: 'STORAGE.REFRESH_QUEUED',
      pending: 'STORAGE.REFRESH_PENDING',
      idle: 'STORAGE.REFRESH_SUCCESS',
    }[status];
    useAlert(t(alertKey || 'STORAGE.REFRESH_ERROR'));
    if (activeTab.value === 'cleaner') await fetchHeavyFiles();
    await fetchTrash();
  } catch (error) {
    if (!current()) return;
    useAlert(error?.response?.data?.message || t('STORAGE.REFRESH_ERROR'));
  } finally {
    if (current()) isRefreshing.value = false;
  }
};

const reloadStorageAfterAction = async () => {
  previewRequestId += 1;
  previewData.value = null;
  await Promise.all([
    fetchStorageInfo(),
    fetchTrash(),
    ...(activeTab.value === 'cleaner' ? [fetchHeavyFiles()] : []),
  ]);
};

watch(
  () => accountId.value,
  () => {
    heavyFilesRequestId += 1;
    storageRequestId += 1;
    trashRequestId += 1;
    previewRequestId += 1;
    storageData.value = null;
    heavyFiles.value = [];
    trashData.value = { total_count: 0, total_bytes: 0, items: [] };
    previewData.value = null;
    recordingsPending.value = false;
    isRefreshing.value = false;
    reloadStorageAfterAction();
  }
);

const onFilterChange = () => {
  if (activeTab.value === 'cleaner') fetchHeavyFiles();
};

const onCleanerTabClick = async () => {
  activeTab.value = 'cleaner';
  await Promise.all([fetchHeavyFiles(), fetchTrash()]);
};

const runPreview = async () => {
  previewRequestId += 1;
  const requestId = previewRequestId;
  const requestAccount = accountId.value;
  const current = () =>
    pageActive &&
    requestId === previewRequestId &&
    requestAccount === accountId.value;
  try {
    isPreviewing.value = true;
    previewData.value = null;
    const params = {
      file_type: cleanerFileType.value,
      older_than_months: cleanerMonths.value,
    };
    if (cleanerInboxId.value) {
      params.inbox_id = cleanerInboxId.value;
    }
    const response = await StorageAPI.previewCleanup(params);
    if (!current()) return;
    previewData.value = response.data;
  } catch (error) {
    if (!current()) return;
    useAlert(error?.response?.data?.message || t('STORAGE.CLEANER.MOVE_ERROR'));
  } finally {
    if (current()) isPreviewing.value = false;
  }
};

const executeMoveToTrash = async () => {
  if (!previewData.value || previewData.value.total_count === 0) return;
  const count = previewData.value.total_count;
  const size =
    previewData.value.total_human || formatBytes(previewData.value.total_bytes);
  const confirmMsg = t('STORAGE.CLEANER.MOVE_CONFIRM', { count, size });

  // eslint-disable-next-line no-alert
  if (!window.confirm(confirmMsg)) return;

  try {
    isMovingToTrash.value = true;
    const params = {
      file_type: cleanerFileType.value,
      older_than_months: cleanerMonths.value,
      preview_token: previewData.value.confirmation_token,
      confirmed: true,
    };
    if (cleanerInboxId.value) {
      params.inbox_id = cleanerInboxId.value;
    }
    const response = await StorageAPI.moveToTrash(params);
    useAlert(
      t('STORAGE.CLEANER.MOVE_SUCCESS', {
        count: response.data.moved_count,
        size: formatBytes(response.data.moved_bytes),
      })
    );
    await reloadStorageAfterAction();
  } catch (error) {
    useAlert(error?.response?.data?.message || t('STORAGE.CLEANER.MOVE_ERROR'));
  } finally {
    isMovingToTrash.value = false;
  }
};

const restoreTrashItem = async item => {
  try {
    isRestoring.value = true;
    await StorageAPI.restoreTrash({
      item_type: item.item_type,
      item_id: item.id,
    });
    useAlert(t('STORAGE.TRASH.RESTORE_SUCCESS'));
    await reloadStorageAfterAction();
  } catch (error) {
    useAlert(error?.response?.data?.message || t('STORAGE.FETCH_ERROR'));
  } finally {
    isRestoring.value = false;
  }
};

const restoreAllTrash = async () => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('STORAGE.TRASH.RESTORE_CONFIRM'))) return;

  try {
    isRestoring.value = true;
    await StorageAPI.restoreTrash({ restore_all: true });
    useAlert(t('STORAGE.TRASH.RESTORE_ALL_SUCCESS'));
    await reloadStorageAfterAction();
  } catch (error) {
    useAlert(error?.response?.data?.message || t('STORAGE.FETCH_ERROR'));
  } finally {
    isRestoring.value = false;
  }
};

const purgeTrashItem = async item => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('STORAGE.TRASH.PURGE_ITEM_CONFIRM'))) return;

  try {
    isPurging.value = true;
    await StorageAPI.emptyTrash({
      item_type: item.item_type,
      item_id: item.id,
      confirmed: true,
    });
    useAlert(t('STORAGE.TRASH.PURGE_SUCCESS'));
    await reloadStorageAfterAction();
  } catch (error) {
    useAlert(error?.response?.data?.message || t('STORAGE.FETCH_ERROR'));
  } finally {
    isPurging.value = false;
  }
};

const emptyAllTrash = async () => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('STORAGE.TRASH.EMPTY_CONFIRM'))) return;

  try {
    isPurging.value = true;
    await StorageAPI.emptyTrash({ confirmed: true });
    useAlert(t('STORAGE.TRASH.EMPTY_SUCCESS'));
    await reloadStorageAfterAction();
  } catch (error) {
    useAlert(error?.response?.data?.message || t('STORAGE.FETCH_ERROR'));
  } finally {
    isPurging.value = false;
  }
};

const isUnlimited = computed(() => !!storageData.value?.unlimited);
const usagePercent = computed(() => storageData.value?.usage_percent || 0);

const storageAlertLevel = computed(() => {
  if (isUnlimited.value || usagePercent.value < 80) return 'normal';
  return usagePercent.value >= 95 ? 'critical' : 'warning';
});

const shouldShowStorageAlert = computed(() => {
  const now = storageAlertClock.value;
  const dismissal = storageAlertDismissal.value;
  return (
    storageAlertLevel.value !== 'normal' &&
    (!dismissal ||
      dismissal.level !== storageAlertLevel.value ||
      now >= dismissal.until)
  );
});

const dismissStorageAlert = () => {
  const dismissal = {
    level: storageAlertLevel.value,
    until: Date.now() + 24 * 60 * 60 * 1000,
  };
  storageAlertDismissal.value = dismissal;
  try {
    window.localStorage.setItem(
      `storage-alert:${accountId.value}`,
      JSON.stringify(dismissal)
    );
  } catch {
    /* Storage can be disabled by the browser; keep the dismissal in memory. */
  }
};

onMounted(async () => {
  try {
    const saved = window.localStorage.getItem(
      `storage-alert:${accountId.value}`
    );
    storageAlertDismissal.value = saved ? JSON.parse(saved) : null;
  } catch {
    storageAlertDismissal.value = null;
  }
  storageAlertTimer = window.setInterval(() => {
    storageAlertClock.value = Date.now();
  }, 60 * 1000);
  await fetchStorageInfo();
  await fetchTrash();
  if (!pageActive) return;
  storagePollTimer = window.setInterval(() => {
    const storage = storageData.value;
    if (
      storage?.refresh_status !== 'failed' &&
      (storage?.calculating || storage?.refresh_pending || storage?.stale)
    ) {
      if (!isLoading.value && !isRefreshing.value) fetchStorageInfo();
    }
    if (
      activeTab.value === 'cleaner' &&
      recordingsPending.value &&
      recordingsRefreshStatus.value !== 'failed' &&
      !isLoadingFiles.value
    )
      fetchHeavyFiles();
  }, 10000);
});

onBeforeUnmount(() => {
  pageActive = false;
  window.clearInterval(storageAlertTimer);
  window.clearInterval(storagePollTimer);
});

const progressBarClass = computed(() => {
  if (isUnlimited.value) return 'bg-slate-400';
  if (usagePercent.value >= 95) return 'bg-red-500';
  if (usagePercent.value >= 80) return 'bg-amber-500';
  return 'bg-emerald-500';
});

const badgeClass = computed(() => {
  if (isUnlimited.value) return 'bg-slate-100 text-slate-700 border-slate-300';
  if (usagePercent.value >= 95) return 'bg-red-100 text-red-800 border-red-300';
  if (usagePercent.value >= 80)
    return 'bg-amber-100 text-amber-800 border-amber-300';
  return 'bg-emerald-100 text-emerald-800 border-emerald-300';
});

const statusText = computed(() => {
  if (isUnlimited.value) return t('STORAGE.OVERVIEW.UNLIMITED');
  if (usagePercent.value >= 95) return t('STORAGE.OVERVIEW.CRITICAL');
  if (usagePercent.value >= 80) return t('STORAGE.OVERVIEW.WARNING');
  return t('STORAGE.OVERVIEW.NORMAL');
});

const breakdown = computed(() => storageData.value?.breakdown || {});
const inboxesList = computed(
  () => storageData.value?.breakdown?.by_inbox || []
);
const trashTotalCount = computed(() => trashData.value?.total_count || 0);
const trashTotalBytes = computed(() => trashData.value?.total_bytes || 0);

const typeCards = computed(() => {
  const bd = breakdown.value;

  const items = [
    {
      key: 'recordings',
      title: t('STORAGE.TYPES.RECORDINGS'),
      icon: '📞',
      bytes: bd.recordings || 0,
    },
    {
      key: 'audio',
      title: t('STORAGE.TYPES.AUDIO'),
      icon: '🎙️',
      bytes: bd.audio || 0,
    },
    {
      key: 'images',
      title: t('STORAGE.TYPES.IMAGES'),
      icon: '🖼️',
      bytes: bd.images || 0,
    },
    {
      key: 'videos',
      title: t('STORAGE.TYPES.VIDEOS'),
      icon: '🎥',
      bytes: bd.videos || 0,
    },
    {
      key: 'documents',
      title: t('STORAGE.TYPES.DOCUMENTS'),
      icon: '📄',
      bytes: bd.documents || 0,
    },
    {
      key: 'captain',
      title: t('STORAGE.TYPES.CAPTAIN'),
      icon: '🤖',
      bytes: bd.captain || 0,
    },
    {
      key: 'other',
      title: t('STORAGE.TYPES.OTHER'),
      icon: '🗂️',
      bytes: bd.other || 0,
    },
  ];

  // Call recordings are shown here even when they do not count towards the quota (total then excludes
  // them), so the shares are taken of whichever is larger: the quota total or what the cards add up to.
  const total =
    Math.max(
      bd.total || 0,
      items.reduce((sum, item) => sum + item.bytes, 0)
    ) || 1;

  return items.map(item => ({
    ...item,
    formatted: formatBytes(item.bytes),
    percent: Math.min(100, Math.round((item.bytes / total) * 100)),
  }));
});

const getFileTypeIcon = type => {
  switch (type) {
    case 'recording':
    case 'recordings':
    case 'original_recording':
      return '📞';
    case 'audio':
      return '🎙️';
    case 'image':
      return '🖼️';
    case 'video':
      return '🎥';
    case 'file':
    case 'document':
      return '📄';
    default:
      return '📎';
  }
};

const getFileTypeName = type => {
  switch (type) {
    case 'recording':
    case 'recordings':
    case 'original_recording':
      return t('STORAGE.TYPES.RECORDINGS');
    case 'audio':
      return t('STORAGE.TYPES.AUDIO');
    case 'image':
      return t('STORAGE.TYPES.IMAGES');
    case 'video':
      return t('STORAGE.TYPES.VIDEOS');
    case 'file':
    case 'document':
      return t('STORAGE.TYPES.DOCUMENTS');
    default:
      return t('STORAGE.TYPES.OTHER');
  }
};
</script>

<template>
  <SettingsLayout
    :is-loading="isLoading"
    :loading-message="$t('STORAGE.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="$t('STORAGE.TITLE')"
        :description="$t('STORAGE.DESCRIPTION')"
      >
        <template #actions>
          <button
            type="button"
            class="button button--secondary button--sm flex items-center gap-1.5"
            :disabled="isRefreshing"
            @click="refreshStorage"
          >
            <span v-if="isRefreshing" class="animate-spin">{{ '🔄' }}</span>
            <span v-else>{{ '↻' }}</span>
            <span>{{
              isRefreshing ? $t('STORAGE.REFRESHING') : $t('STORAGE.REFRESH')
            }}</span>
          </button>
        </template>
      </BaseSettingsHeader>
    </template>

    <template #body>
      <div
        v-if="!isLoading && storageData?.calculating"
        class="rounded-xl border border-slate-200 bg-white p-6 text-slate-700"
        role="status"
      >
        {{
          $t(
            storageData.refresh_status === 'failed'
              ? 'STORAGE.REFRESH_ERROR'
              : 'STORAGE.CALCULATING'
          )
        }}
      </div>
      <div v-else-if="!isLoading && storageData" class="space-y-6">
        <p
          v-if="storageData.refresh_pending || storageData.stale"
          class="text-xs text-slate-600"
          role="status"
        >
          {{
            $t(
              storageData.refresh_status === 'failed'
                ? 'STORAGE.REFRESH_ERROR'
                : 'STORAGE.REFRESH_PENDING'
            )
          }}
        </p>
        <!-- Storage Threshold Alert Banner (80% / 95%) -->
        <div
          v-if="shouldShowStorageAlert"
          class="rounded-xl border p-4 sm:p-5 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 transition-all"
          :class="
            usagePercent >= 95
              ? 'bg-red-50 border-red-200 text-red-900 shadow-sm'
              : 'bg-amber-50 border-amber-200 text-amber-900 shadow-sm'
          "
        >
          <div class="flex items-start gap-3.5">
            <span class="text-2xl flex-shrink-0 mt-0.5">
              {{ usagePercent >= 95 ? '🚨' : '⚠️' }}
            </span>
            <div>
              <h4 class="text-sm font-bold">
                {{
                  usagePercent >= 95
                    ? $t('STORAGE.ALERTS.CRITICAL_TITLE', {
                        percentage: usagePercent,
                      })
                    : $t('STORAGE.ALERTS.WARNING_TITLE', {
                        percentage: usagePercent,
                      })
                }}
              </h4>
              <p
                class="text-xs mt-1"
                :class="usagePercent >= 95 ? 'text-red-700' : 'text-amber-800'"
              >
                {{
                  usagePercent >= 95
                    ? $t('STORAGE.ALERTS.CRITICAL_MESSAGE', {
                        used: formatBytes(storageData.consumed_bytes),
                        limit: formatBytes(storageData.total_limit_bytes),
                      })
                    : $t('STORAGE.ALERTS.WARNING_MESSAGE', {
                        used: formatBytes(storageData.consumed_bytes),
                        limit: formatBytes(storageData.total_limit_bytes),
                      })
                }}
              </p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button
              type="button"
              class="flex-shrink-0 whitespace-nowrap text-xs font-semibold px-4 py-2 rounded-lg transition text-white shadow-sm"
              :class="
                usagePercent >= 95
                  ? 'bg-red-600 hover:bg-red-700'
                  : 'bg-amber-600 hover:bg-amber-700'
              "
              @click="onCleanerTabClick"
            >
              {{ $t('STORAGE.ALERTS.CLEAN_BUTTON') }}
            </button>
            <button
              type="button"
              class="text-xs underline"
              @click="dismissStorageAlert"
            >
              {{ $t('STORAGE.ALERTS.DISMISS') }}
            </button>
          </div>
        </div>

        <!-- Storage Quota Bar Card -->
        <div
          class="p-5 sm:p-6 bg-white rounded-xl border border-slate-200 shadow-sm"
        >
          <div
            class="flex flex-col sm:flex-row sm:items-center justify-between gap-2 mb-4"
          >
            <div>
              <h3 class="text-base font-bold text-slate-900">
                {{ $t('STORAGE.OVERVIEW.TITLE') }}
              </h3>
              <p class="text-xs text-slate-500 mt-0.5">
                {{
                  `${$t('STORAGE.OVERVIEW.LAST_UPDATED')}: ${formatDate(storageData.last_updated_at)}`
                }}
              </p>
            </div>
            <div class="flex items-center gap-2">
              <span
                class="px-2.5 py-1 text-xs font-semibold rounded-full border"
                :class="badgeClass"
              >
                {{ statusText }}
              </span>
            </div>
          </div>

          <div class="flex items-baseline justify-between text-sm mb-2">
            <span class="font-bold text-slate-900 text-lg">
              {{ formatBytes(storageData.consumed_bytes) }}
            </span>
            <span class="text-slate-500 font-medium text-xs">
              {{
                isUnlimited
                  ? $t('STORAGE.OVERVIEW.UNLIMITED')
                  : `${formatBytes(storageData.total_limit_bytes)} (${$t('STORAGE.OVERVIEW.AVAILABLE')}: ${formatBytes(storageData.available_bytes)})`
              }}
            </span>
          </div>

          <!-- Progress Bar -->
          <div
            class="w-full bg-slate-100 rounded-full h-3 overflow-hidden p-0.5 border border-slate-200"
          >
            <div
              class="h-2 rounded-full transition-all duration-500"
              :class="progressBarClass"
              :style="{
                width: `${isUnlimited ? 100 : Math.min(100, Math.max(usagePercent, 2))}%`,
              }"
            />
          </div>

          <div
            class="flex items-center justify-between text-[11px] text-slate-400 mt-2 font-mono"
          >
            <span>{{ '0%' }}</span>
            <span>{{ isUnlimited ? '∞' : `${usagePercent}%` }}</span>
          </div>
        </div>

        <!-- Navigation Tabs -->
        <div class="flex items-center gap-2 border-b border-slate-200">
          <button
            class="px-4 py-2.5 text-sm font-semibold border-b-2 transition -mb-px flex items-center gap-1.5"
            :class="
              activeTab === 'overview'
                ? 'border-blue-600 text-blue-600'
                : 'border-transparent text-slate-500 hover:text-slate-700'
            "
            @click="activeTab = 'overview'"
          >
            <span>{{ '📊' }}</span>
            <span>{{ $t('STORAGE.TABS.OVERVIEW') }}</span>
          </button>
          <button
            class="px-4 py-2.5 text-sm font-semibold border-b-2 transition -mb-px flex items-center gap-2"
            :class="
              activeTab === 'cleaner'
                ? 'border-blue-600 text-blue-600'
                : 'border-transparent text-slate-500 hover:text-slate-700'
            "
            @click="onCleanerTabClick"
          >
            <span>{{ '🧹' }}</span>
            <span>{{ $t('STORAGE.TABS.CLEANER') }}</span>
            <span
              v-if="trashTotalCount > 0"
              class="px-2 py-0.5 text-[10px] rounded-full bg-amber-100 text-amber-800 font-bold"
            >
              {{ trashTotalCount }}
            </span>
          </button>
        </div>

        <!-- TAB 1: OVERVIEW -->
        <div v-if="activeTab === 'overview'" class="space-y-6">
          <!-- File Types Breakdown Grid -->
          <div>
            <h4
              class="text-sm font-bold text-slate-800 uppercase tracking-wider mb-3"
            >
              {{ $t('STORAGE.TYPES.TITLE') }}
            </h4>
            <div
              class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-7 gap-3"
            >
              <div
                v-for="card in typeCards"
                :key="card.key"
                class="p-4 bg-white rounded-xl border border-slate-200 shadow-sm flex flex-col justify-between"
              >
                <div>
                  <div
                    class="flex items-center justify-between text-slate-500 text-xs"
                  >
                    <span class="text-base">{{ card.icon }}</span>
                    <span class="font-mono text-[10px]">{{
                      `${card.percent}%`
                    }}</span>
                  </div>
                  <p class="text-xs font-medium text-slate-600 mt-2 truncate">
                    {{ card.title }}
                  </p>
                </div>
                <div class="mt-2">
                  <span class="text-sm font-bold text-slate-900 block truncate">
                    {{ card.formatted }}
                  </span>
                </div>
              </div>
            </div>
          </div>

          <!-- Inboxes Storage Consumption Grid -->
          <div v-if="inboxesList.length > 0">
            <h4
              class="text-sm font-bold text-slate-800 uppercase tracking-wider mb-3"
            >
              {{ $t('STORAGE.INBOXES.TITLE') }}
            </h4>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
              <div
                v-for="inbox in inboxesList"
                :key="inbox.id"
                class="p-4 bg-white rounded-xl border border-slate-200 shadow-sm flex items-center justify-between"
              >
                <div class="min-w-0 pr-3">
                  <p class="text-sm font-semibold text-slate-900 truncate">
                    {{ inbox.name }}
                  </p>
                  <p class="text-xs text-slate-500 mt-0.5">
                    {{
                      `${inbox.files_count} ${$t('STORAGE.INBOXES.FILES_COUNT')}`
                    }}
                  </p>
                </div>
                <div class="text-right flex-shrink-0">
                  <span class="text-sm font-bold text-slate-900">
                    {{ formatBytes(inbox.bytes) }}
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- TAB 2: CLEANER & TRASH -->
        <div v-else-if="activeTab === 'cleaner'" class="space-y-6">
          <!-- Smart Cleaner Form Card -->
          <div
            class="p-5 sm:p-6 bg-white rounded-xl border border-slate-200 shadow-sm"
          >
            <div class="border-b border-slate-100 pb-4 mb-4">
              <h3
                class="text-base font-bold text-slate-900 flex items-center gap-2"
              >
                <span>{{ '🧹' }}</span>
                <span>{{ $t('STORAGE.CLEANER.TITLE') }}</span>
              </h3>
              <p class="text-xs text-slate-500 mt-1">
                {{ $t('STORAGE.CLEANER.SUBTITLE') }}
              </p>
            </div>

            <!-- Cleaner Filters Form -->
            <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-4">
              <div>
                <label class="block text-xs font-semibold text-slate-700 mb-1">
                  {{ $t('STORAGE.CLEANER.FILE_TYPE') }}
                </label>
                <select
                  v-model="cleanerFileType"
                  class="w-full text-xs border border-slate-300 rounded-lg px-3 py-2 bg-white text-slate-700 focus:outline-none focus:ring-1 focus:ring-blue-500"
                >
                  <option value="all">
                    {{ $t('STORAGE.CLEANER.ALL_TYPES') }}
                  </option>
                  <option value="recordings">
                    {{ $t('STORAGE.TYPES.RECORDINGS') }}
                  </option>
                  <option value="audio">
                    {{ $t('STORAGE.TYPES.AUDIO') }}
                  </option>
                  <option value="image">
                    {{ $t('STORAGE.TYPES.IMAGES') }}
                  </option>
                  <option value="video">
                    {{ $t('STORAGE.TYPES.VIDEOS') }}
                  </option>
                  <option value="file">
                    {{ $t('STORAGE.TYPES.DOCUMENTS') }}
                  </option>
                </select>
              </div>

              <div>
                <label class="block text-xs font-semibold text-slate-700 mb-1">
                  {{ $t('STORAGE.CLEANER.OLDER_THAN') }}
                </label>
                <select
                  v-model="cleanerMonths"
                  class="w-full text-xs border border-slate-300 rounded-lg px-3 py-2 bg-white text-slate-700 focus:outline-none focus:ring-1 focus:ring-blue-500"
                >
                  <option :value="1">
                    {{ $t('STORAGE.CLEANER.OLDER_1_MONTH') }}
                  </option>
                  <option :value="3">
                    {{ $t('STORAGE.CLEANER.OLDER_3_MONTHS') }}
                  </option>
                  <option :value="6">
                    {{ $t('STORAGE.CLEANER.OLDER_6_MONTHS') }}
                  </option>
                  <option :value="12">
                    {{ $t('STORAGE.CLEANER.OLDER_1_YEAR') }}
                  </option>
                </select>
              </div>

              <div>
                <label class="block text-xs font-semibold text-slate-700 mb-1">
                  {{ $t('STORAGE.HEAVY_FILES.COLUMNS.INBOX') }}
                </label>
                <select
                  v-model="cleanerInboxId"
                  class="w-full text-xs border border-slate-300 rounded-lg px-3 py-2 bg-white text-slate-700 focus:outline-none focus:ring-1 focus:ring-blue-500 truncate"
                >
                  <option value="">
                    {{ $t('STORAGE.HEAVY_FILES.ALL_INBOXES') }}
                  </option>
                  <option
                    v-for="inbox in inboxesList"
                    :key="inbox.id"
                    :value="inbox.id"
                  >
                    {{ inbox.name }}
                  </option>
                </select>
              </div>
            </div>

            <!-- Preview action button -->
            <div class="flex items-center gap-3">
              <button
                type="button"
                class="button button--primary button--sm flex items-center gap-1.5"
                :disabled="isPreviewing"
                @click="runPreview"
              >
                <span v-if="isPreviewing" class="animate-spin">{{ '🔄' }}</span>
                <span>{{
                  isPreviewing
                    ? $t('STORAGE.CLEANER.PREVIEWING')
                    : $t('STORAGE.CLEANER.PREVIEW_BUTTON')
                }}</span>
              </button>
            </div>

            <!-- Preview Results Box -->
            <div
              v-if="previewData"
              class="mt-5 p-4 rounded-xl border border-blue-200 bg-blue-50/50 space-y-4"
            >
              <div class="flex items-center justify-between">
                <h4 class="text-sm font-bold text-blue-900">
                  {{ $t('STORAGE.CLEANER.PREVIEW_TITLE') }}
                </h4>
                <span class="text-xs font-mono font-bold text-blue-700">
                  {{
                    previewData.total_human ||
                    formatBytes(previewData.total_bytes)
                  }}
                </span>
              </div>

              <div
                v-if="previewData.total_count === 0"
                class="text-xs text-slate-600"
              >
                {{ $t('STORAGE.CLEANER.NO_MATCHING_FILES') }}
              </div>
              <div v-else class="space-y-3">
                <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 text-xs">
                  <div class="bg-white p-2.5 rounded-lg border border-blue-100">
                    <span class="text-slate-500 block">{{
                      $t('STORAGE.CLEANER.FOUND_FILES')
                    }}</span>
                    <strong class="text-slate-900 text-sm">{{
                      previewData.total_count
                    }}</strong>
                  </div>
                  <div class="bg-white p-2.5 rounded-lg border border-blue-100">
                    <span class="text-slate-500 block">{{
                      $t('STORAGE.CLEANER.TO_TRASH_SIZE')
                    }}</span>
                    <strong class="text-slate-900 text-sm">{{
                      previewData.total_human ||
                      formatBytes(previewData.total_bytes)
                    }}</strong>
                  </div>
                  <div class="bg-white p-2.5 rounded-lg border border-blue-100">
                    <span class="text-slate-500 block">{{
                      $t('STORAGE.TYPES.RECORDINGS')
                    }}</span>
                    <strong class="text-slate-900 text-sm">{{
                      `${previewData.recordings_count} (${formatBytes(previewData.recordings_bytes)})`
                    }}</strong>
                  </div>
                  <div class="bg-white p-2.5 rounded-lg border border-blue-100">
                    <span class="text-slate-500 block">{{
                      $t('STORAGE.TYPES.DOCUMENTS')
                    }}</span>
                    <strong class="text-slate-900 text-sm">{{
                      `${previewData.attachments_count} (${formatBytes(previewData.attachments_bytes)})`
                    }}</strong>
                  </div>
                </div>

                <!-- Retention notice -->
                <p
                  class="text-xs text-blue-800 bg-blue-100/60 p-2.5 rounded-lg border border-blue-200"
                >
                  {{ 'ℹ️ ' + $t('STORAGE.CLEANER.RETENTION_NOTICE') }}
                </p>

                <!-- Move to trash confirm button -->
                <button
                  type="button"
                  class="button button--alert button--sm flex items-center gap-1.5"
                  :disabled="isMovingToTrash"
                  @click="executeMoveToTrash"
                >
                  <span v-if="isMovingToTrash" class="animate-spin">{{
                    '🔄'
                  }}</span>
                  <span>{{
                    isMovingToTrash
                      ? $t('STORAGE.CLEANER.MOVING')
                      : $t('STORAGE.CLEANER.MOVE_BUTTON')
                  }}</span>
                </button>
              </div>
            </div>
          </div>

          <!-- Heavy Files Table -->
          <div
            class="bg-white rounded-xl border border-slate-200 shadow-sm overflow-hidden"
          >
            <div
              class="p-4 sm:p-5 border-b border-slate-100 flex flex-col md:flex-row md:items-center justify-between gap-4"
            >
              <div>
                <h4 class="text-base font-bold text-slate-900">
                  {{ $t('STORAGE.HEAVY_FILES.TITLE') }}
                </h4>
                <p class="text-xs text-slate-500 mt-0.5">
                  {{ $t('STORAGE.HEAVY_FILES.SUBTITLE') }}
                </p>
              </div>

              <!-- Filters -->
              <div class="flex flex-wrap items-center gap-2.5">
                <select
                  v-model="selectedFileType"
                  class="text-xs border border-slate-300 rounded-lg px-2.5 py-1.5 bg-white text-slate-700 focus:outline-none focus:ring-1 focus:ring-blue-500"
                  @change="onFilterChange"
                >
                  <option value="all">
                    {{ $t('STORAGE.HEAVY_FILES.ALL_TYPES') }}
                  </option>
                  <option value="recordings">
                    {{ $t('STORAGE.TYPES.RECORDINGS') }}
                  </option>
                  <option value="audio">
                    {{ $t('STORAGE.TYPES.AUDIO') }}
                  </option>
                  <option value="images">
                    {{ $t('STORAGE.TYPES.IMAGES') }}
                  </option>
                  <option value="documents">
                    {{ $t('STORAGE.TYPES.DOCUMENTS') }}
                  </option>
                  <option value="videos">
                    {{ $t('STORAGE.TYPES.VIDEOS') }}
                  </option>
                </select>

                <select
                  v-if="inboxesList.length > 0"
                  v-model="selectedInboxId"
                  class="text-xs border border-slate-300 rounded-lg px-2.5 py-1.5 bg-white text-slate-700 focus:outline-none focus:ring-1 focus:ring-blue-500 max-w-[160px] truncate"
                  @change="onFilterChange"
                >
                  <option value="">
                    {{ $t('STORAGE.HEAVY_FILES.ALL_INBOXES') }}
                  </option>
                  <option
                    v-for="inbox in inboxesList"
                    :key="inbox.id"
                    :value="inbox.id"
                  >
                    {{ inbox.name }}
                  </option>
                </select>
                <input
                  v-model="selectedConversationId"
                  type="number"
                  min="1"
                  class="w-28 text-xs border border-slate-300 rounded-lg px-2.5 py-1.5"
                  :aria-label="$t('STORAGE.HEAVY_FILES.CONVERSATION_ID')"
                  :placeholder="$t('STORAGE.HEAVY_FILES.CONVERSATION_ID')"
                  @change="onFilterChange"
                />
                <input
                  v-model="selectedDateFrom"
                  type="date"
                  class="text-xs border border-slate-300 rounded-lg px-2.5 py-1.5"
                  :aria-label="$t('STORAGE.HEAVY_FILES.DATE_FROM')"
                  @change="onFilterChange"
                />
                <input
                  v-model="selectedDateTo"
                  type="date"
                  class="text-xs border border-slate-300 rounded-lg px-2.5 py-1.5"
                  :aria-label="$t('STORAGE.HEAVY_FILES.DATE_TO')"
                  @change="onFilterChange"
                />
              </div>
            </div>

            <p
              v-if="recordingsPending && !isLoadingFiles"
              class="px-4 pt-4 text-xs text-slate-600"
              role="status"
            >
              {{
                $t(
                  recordingsRefreshStatus === 'failed'
                    ? 'STORAGE.HEAVY_FILES.RECORDINGS_UNAVAILABLE'
                    : 'STORAGE.HEAVY_FILES.RECORDINGS_PENDING'
                )
              }}
            </p>

            <!-- Files list table -->
            <div
              v-if="isLoadingFiles"
              class="p-8 text-center text-xs text-slate-400"
            >
              {{ $t('STORAGE.LOADING') }}
            </div>
            <div
              v-else-if="heavyFiles.length === 0 && !recordingsPending"
              class="p-8 text-center text-xs text-slate-400"
            >
              {{
                $t(
                  heavyFilesError
                    ? 'STORAGE.HEAVY_FILES_ERROR'
                    : 'STORAGE.HEAVY_FILES.EMPTY'
                )
              }}
            </div>
            <div v-else-if="heavyFiles.length > 0" class="overflow-x-auto">
              <table class="w-full text-left text-xs">
                <thead
                  class="bg-slate-50 text-slate-500 uppercase font-semibold border-b border-slate-200"
                >
                  <tr>
                    <th class="px-4 py-3">
                      {{ $t('STORAGE.HEAVY_FILES.COLUMNS.NAME') }}
                    </th>
                    <th class="px-4 py-3">
                      {{ $t('STORAGE.HEAVY_FILES.COLUMNS.TYPE') }}
                    </th>
                    <th class="px-4 py-3">
                      {{ $t('STORAGE.HEAVY_FILES.COLUMNS.INBOX') }}
                    </th>
                    <th class="px-4 py-3">
                      {{ $t('STORAGE.HEAVY_FILES.COLUMNS.SIZE') }}
                    </th>
                    <th class="px-4 py-3">
                      {{ $t('STORAGE.HEAVY_FILES.COLUMNS.DATE') }}
                    </th>
                    <th class="px-4 py-3 text-right">
                      {{ $t('STORAGE.HEAVY_FILES.COLUMNS.ACTIONS') }}
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-slate-100">
                  <tr
                    v-for="file in heavyFiles"
                    :key="file.id"
                    class="hover:bg-slate-50/80 transition"
                  >
                    <td class="px-4 py-3">
                      <div
                        class="flex items-center gap-2 max-w-[280px] sm:max-w-[360px]"
                      >
                        <span class="text-base flex-shrink-0">{{
                          getFileTypeIcon(file.file_type)
                        }}</span>
                        <span
                          class="font-medium text-slate-900 truncate"
                          :title="file.name"
                        >
                          {{ file.name }}
                        </span>
                      </div>
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap">
                      <span
                        class="px-2 py-0.5 text-[10px] font-semibold rounded bg-slate-100 text-slate-700"
                      >
                        {{ getFileTypeName(file.file_type) }}
                      </span>
                    </td>
                    <td class="px-4 py-3 text-slate-600 whitespace-nowrap">
                      {{ file.inbox_name }}
                    </td>
                    <td
                      class="px-4 py-3 font-semibold text-slate-900 whitespace-nowrap"
                    >
                      {{ file.human_size }}
                    </td>
                    <td class="px-4 py-3 text-slate-500 whitespace-nowrap">
                      {{ formatDate(file.created_at) }}
                    </td>
                    <td class="px-4 py-3 text-right whitespace-nowrap">
                      <div class="inline-flex items-center gap-2">
                        <router-link
                          v-if="file.conversation_id"
                          :to="{
                            name: 'inbox_conversation',
                            params: {
                              conversation_id: file.conversation_id,
                            },
                          }"
                          class="text-blue-600 hover:text-blue-800 font-medium hover:underline"
                        >
                          {{
                            $t('STORAGE.HEAVY_FILES.ACTIONS.OPEN_CONVERSATION')
                          }}
                        </router-link>
                        <a
                          v-if="file.download_url"
                          :href="file.download_url"
                          target="_blank"
                          rel="noopener noreferrer"
                          class="text-slate-500 hover:text-slate-700 font-medium hover:underline"
                        >
                          {{ $t('STORAGE.HEAVY_FILES.ACTIONS.DOWNLOAD') }}
                        </a>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <!-- Trash List Card -->
          <div
            class="bg-white rounded-xl border border-slate-200 shadow-sm overflow-hidden"
          >
            <div
              class="p-4 sm:p-5 border-b border-slate-100 flex flex-col md:flex-row md:items-center justify-between gap-4"
            >
              <div>
                <h4
                  class="text-base font-bold text-slate-900 flex items-center gap-2"
                >
                  <span>{{ '🗑️' }}</span>
                  <span>{{ $t('STORAGE.TRASH.TITLE') }}</span>
                </h4>
                <p class="text-xs text-slate-500 mt-0.5">
                  {{
                    `${$t('STORAGE.TRASH.TOTAL_IN_TRASH')} ${trashTotalCount} (${formatBytes(trashTotalBytes)})`
                  }}
                </p>
              </div>

              <!-- Trash Bulk Actions -->
              <div v-if="trashTotalCount > 0" class="flex items-center gap-2">
                <button
                  type="button"
                  class="button button--secondary button--xs"
                  :disabled="isRestoring || isPurging"
                  @click="restoreAllTrash"
                >
                  <span>{{ '🔄' }}</span>
                  <span>{{ $t('STORAGE.TRASH.RESTORE_ALL') }}</span>
                </button>
                <button
                  type="button"
                  class="button button--alert button--xs"
                  :disabled="isRestoring || isPurging"
                  @click="emptyAllTrash"
                >
                  <span>{{ '🔥' }}</span>
                  <span>{{ $t('STORAGE.TRASH.EMPTY_TRASH') }}</span>
                </button>
              </div>
            </div>

            <!-- Trash items list -->
            <div
              v-if="isLoadingTrash"
              class="p-8 text-center text-xs text-slate-400"
            >
              {{ $t('STORAGE.LOADING') }}
            </div>
            <div
              v-else-if="trashData.items.length === 0"
              class="p-8 text-center text-xs text-slate-400"
            >
              {{ $t('STORAGE.TRASH.EMPTY') }}
            </div>
            <div v-else class="overflow-x-auto">
              <table class="w-full text-left text-xs">
                <thead
                  class="bg-slate-50 text-slate-500 uppercase font-semibold border-b border-slate-200"
                >
                  <tr>
                    <th class="px-4 py-3">
                      {{ $t('STORAGE.TRASH.COLUMNS.NAME') }}
                    </th>
                    <th class="px-4 py-3">
                      {{ $t('STORAGE.TRASH.COLUMNS.TYPE') }}
                    </th>
                    <th class="px-4 py-3">
                      {{ $t('STORAGE.TRASH.COLUMNS.INBOX') }}
                    </th>
                    <th class="px-4 py-3">
                      {{ $t('STORAGE.TRASH.COLUMNS.SIZE') }}
                    </th>
                    <th class="px-4 py-3">
                      {{ $t('STORAGE.TRASH.COLUMNS.DELETED_AT') }}
                    </th>
                    <th class="px-4 py-3">
                      {{ $t('STORAGE.TRASH.COLUMNS.EXPIRES_IN') }}
                    </th>
                    <th class="px-4 py-3 text-right">
                      {{ $t('STORAGE.TRASH.COLUMNS.ACTIONS') }}
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-slate-100">
                  <tr
                    v-for="item in trashData.items"
                    :key="`${item.item_type}_${item.id}`"
                    class="hover:bg-slate-50/80 transition"
                  >
                    <td class="px-4 py-3">
                      <div
                        class="flex items-center gap-2 max-w-[240px] sm:max-w-[320px]"
                      >
                        <span class="text-base flex-shrink-0">{{
                          getFileTypeIcon(item.file_type)
                        }}</span>
                        <span
                          class="font-medium text-slate-900 truncate"
                          :title="item.file_name"
                        >
                          {{ item.file_name }}
                        </span>
                      </div>
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap">
                      <span
                        class="px-2 py-0.5 text-[10px] font-semibold rounded bg-slate-100 text-slate-700"
                      >
                        {{ getFileTypeName(item.file_type) }}
                      </span>
                    </td>
                    <td class="px-4 py-3 text-slate-600 whitespace-nowrap">
                      {{ item.inbox_name || '—' }}
                    </td>
                    <td
                      class="px-4 py-3 font-semibold text-slate-900 whitespace-nowrap"
                    >
                      {{ formatBytes(item.byte_size) }}
                    </td>
                    <td class="px-4 py-3 text-slate-500 whitespace-nowrap">
                      {{ formatDate(item.deleted_at) }}
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap">
                      <span
                        class="px-2 py-0.5 text-[10px] font-bold rounded"
                        :class="
                          item.days_remaining <= 3
                            ? 'bg-red-100 text-red-700'
                            : item.days_remaining <= 7
                              ? 'bg-amber-100 text-amber-800'
                              : 'bg-slate-100 text-slate-700'
                        "
                      >
                        {{
                          $t('STORAGE.TRASH.DAYS_LEFT', {
                            days: item.days_remaining,
                          })
                        }}
                      </span>
                    </td>
                    <td class="px-4 py-3 text-right whitespace-nowrap">
                      <div class="inline-flex items-center gap-2">
                        <button
                          type="button"
                          class="text-blue-600 hover:text-blue-800 font-semibold"
                          :disabled="isRestoring || isPurging"
                          @click="restoreTrashItem(item)"
                        >
                          {{ $t('STORAGE.TRASH.RESTORE') }}
                        </button>
                        <button
                          type="button"
                          class="text-red-500 hover:text-red-700 font-semibold"
                          :disabled="isRestoring || isPurging"
                          @click="purgeTrashItem(item)"
                        >
                          {{ $t('STORAGE.TRASH.PURGE') }}
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
