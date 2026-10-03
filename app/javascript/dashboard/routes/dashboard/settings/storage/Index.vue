<script setup>
import { ref, computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import StorageAPI from 'dashboard/api/storage';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';

const { t } = useI18n();

const isLoading = ref(true);
const isRefreshing = ref(false);
const storageData = ref(null);
const heavyFiles = ref([]);
const isLoadingFiles = ref(false);

const selectedFileType = ref('all');
const selectedInboxId = ref('');

const formatBytes = (bytes, decimals = 2) => {
  if (!bytes || bytes === 0) return '0 B';
  const k = 1024;
  const dm = decimals < 0 ? 0 : decimals;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${parseFloat((bytes / k ** i).toFixed(dm))} ${sizes[i]}`;
};

const formatDate = dateStr => {
  if (!dateStr) return '—';
  try {
    const d = new Date(dateStr);
    return d.toLocaleString('ru-RU', {
      day: '2-digit',
      month: '2-digit',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  } catch {
    return dateStr;
  }
};

const fetchHeavyFiles = async () => {
  try {
    isLoadingFiles.value = true;
    const params = {
      file_type: selectedFileType.value,
      limit: 50,
    };
    if (selectedInboxId.value) {
      params.inbox_id = selectedInboxId.value;
    }
    const response = await StorageAPI.getHeavyFiles(params);
    heavyFiles.value = response.data.files || [];
  } catch (error) {
    useAlert(error?.response?.data?.message || t('STORAGE.HEAVY_FILES_ERROR'));
  } finally {
    isLoadingFiles.value = false;
  }
};

const fetchStorageInfo = async () => {
  try {
    isLoading.value = true;
    const response = await StorageAPI.get();
    storageData.value = response.data.storage;
  } catch (error) {
    useAlert(error?.response?.data?.message || t('STORAGE.FETCH_ERROR'));
  } finally {
    isLoading.value = false;
  }
};

const refreshStorage = async () => {
  try {
    isRefreshing.value = true;
    const response = await StorageAPI.refresh();
    storageData.value = response.data.storage;
    useAlert(t('STORAGE.REFRESH_SUCCESS'));
    await fetchHeavyFiles();
  } catch (error) {
    useAlert(error?.response?.data?.message || t('STORAGE.REFRESH_ERROR'));
  } finally {
    isRefreshing.value = false;
  }
};

const onFilterChange = () => {
  fetchHeavyFiles();
};

onMounted(async () => {
  await fetchStorageInfo();
  await fetchHeavyFiles();
});

const isUnlimited = computed(() => !!storageData.value?.unlimited);
const usagePercent = computed(() => storageData.value?.usage_percent || 0);

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

const typeCards = computed(() => {
  const bd = breakdown.value;
  const total = bd.total || 1;

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
      key: 'documents',
      title: t('STORAGE.TYPES.DOCUMENTS'),
      icon: '📄',
      bytes: bd.documents || 0,
    },
    {
      key: 'videos',
      title: t('STORAGE.TYPES.VIDEOS'),
      icon: '🎥',
      bytes: bd.videos || 0,
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

  return items.map(item => ({
    ...item,
    formattedSize: formatBytes(item.bytes),
    percent: Math.min(100, Math.round((item.bytes / total) * 100)),
  }));
});

const getFileTypeIcon = fileType => {
  switch (fileType) {
    case 'recording':
      return '📞';
    case 'audio':
      return '🎙️';
    case 'image':
      return '🖼️';
    case 'video':
      return '🎥';
    case 'document':
      return '📄';
    default:
      return '📁';
  }
};

const getFileTypeName = fileType => {
  switch (fileType) {
    case 'recording':
      return t('STORAGE.TYPES.RECORDINGS');
    case 'audio':
      return t('STORAGE.TYPES.AUDIO');
    case 'image':
      return t('STORAGE.TYPES.IMAGES');
    case 'video':
      return t('STORAGE.TYPES.VIDEOS');
    case 'document':
      return t('STORAGE.TYPES.DOCUMENTS');
    default:
      return fileType;
  }
};
</script>

<template>
  <SettingsLayout
    :is-loading="isLoading"
    :loading-message="$t('STORAGE.LOADING')"
    :no-records-found="false"
  >
    <template #header>
      <BaseSettingsHeader
        :title="$t('STORAGE.TITLE')"
        :description="$t('STORAGE.DESCRIPTION')"
      >
        <template #actions>
          <button
            type="button"
            class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 transition shadow-sm disabled:opacity-50"
            :disabled="isRefreshing"
            @click="refreshStorage"
          >
            <span
              class="i-lucide-refresh-cw w-3.5 h-3.5 inline-block"
              :class="{ 'animate-spin': isRefreshing }"
            />
            <span>{{
              isRefreshing ? $t('STORAGE.REFRESHING') : $t('STORAGE.REFRESH')
            }}</span>
          </button>
        </template>
      </BaseSettingsHeader>
    </template>

    <template #body>
      <div v-if="storageData" class="space-y-6 pb-12">
        <!-- Main Overview Card -->
        <div class="p-6 bg-white rounded-xl border border-slate-200 shadow-sm">
          <div
            class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 mb-4"
          >
            <div>
              <div class="flex items-center gap-3">
                <h3 class="text-lg font-bold text-slate-900">
                  {{ $t('STORAGE.OVERVIEW.TITLE') }}
                </h3>
                <span
                  class="px-2.5 py-0.5 text-xs font-semibold rounded-full border"
                  :class="badgeClass"
                >
                  {{ statusText }}
                </span>
              </div>
              <p class="text-xs text-slate-500 mt-1">
                {{
                  `${$t('STORAGE.OVERVIEW.LAST_UPDATED')}: ${formatDate(
                    storageData.last_updated_at
                  )}`
                }}
              </p>
            </div>

            <div class="text-left sm:text-right">
              <div class="text-2xl font-black text-slate-900">
                {{ formatBytes(storageData.consumed_bytes) }}
                <span
                  v-if="!isUnlimited"
                  class="text-sm font-normal text-slate-500"
                >
                  {{ `/ ${formatBytes(storageData.total_limit_bytes)}` }}
                </span>
              </div>
              <p v-if="!isUnlimited" class="text-xs text-slate-500">
                {{
                  `${$t('STORAGE.OVERVIEW.AVAILABLE')}: ${formatBytes(
                    storageData.available_bytes
                  )} (${(100 - usagePercent).toFixed(1)}%)`
                }}
              </p>
            </div>
          </div>

          <!-- Progress bar -->
          <div
            class="w-full bg-slate-100 rounded-full h-3.5 overflow-hidden p-0.5 border border-slate-200"
          >
            <div
              class="h-2.5 rounded-full transition-all duration-500"
              :class="progressBarClass"
              :style="{
                width: isUnlimited ? '100%' : `${Math.max(usagePercent, 2)}%`,
              }"
            />
          </div>

          <div
            class="flex items-center justify-between text-[11px] text-slate-400 mt-2"
          >
            <span>{{ formatBytes(0) }}</span>
            <span>
              {{
                isUnlimited
                  ? $t('STORAGE.OVERVIEW.UNLIMITED')
                  : `${usagePercent}% (${formatBytes(
                      storageData.consumed_bytes
                    )})`
              }}
            </span>
          </div>
        </div>

        <!-- Breakdown by Data Type -->
        <div>
          <h4
            class="text-sm font-bold text-slate-800 uppercase tracking-wider mb-3"
          >
            {{ $t('STORAGE.TYPES.TITLE') }}
          </h4>
          <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3">
            <div
              v-for="item in typeCards"
              :key="item.key"
              class="p-4 bg-white rounded-xl border border-slate-200 shadow-sm flex flex-col justify-between"
            >
              <div>
                <div
                  class="flex items-center gap-2 text-xs font-semibold text-slate-600"
                >
                  <span class="text-base">{{ item.icon }}</span>
                  <span class="truncate">{{ item.title }}</span>
                </div>
                <div class="text-lg font-bold text-slate-900 mt-2">
                  {{ item.formattedSize }}
                </div>
              </div>
              <div class="mt-3">
                <div
                  class="flex items-center justify-between text-[10px] text-slate-400 mb-1"
                >
                  <span>{{ $t('STORAGE.TYPES.SHARE') }}</span>
                  <span>{{ `${item.percent}%` }}</span>
                </div>
                <div
                  class="w-full bg-slate-100 rounded-full h-1.5 overflow-hidden"
                >
                  <div
                    class="bg-blue-500 h-1.5 rounded-full"
                    :style="{ width: `${item.percent}%` }"
                  />
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Breakdown by Inboxes (Channels) -->
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
            <div class="flex items-center gap-2.5">
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
            </div>
          </div>

          <!-- Files list table -->
          <div
            v-if="isLoadingFiles"
            class="p-8 text-center text-xs text-slate-400"
          >
            {{ $t('STORAGE.LOADING') }}
          </div>
          <div
            v-else-if="heavyFiles.length === 0"
            class="p-8 text-center text-xs text-slate-400"
          >
            {{ $t('STORAGE.HEAVY_FILES.EMPTY') }}
          </div>
          <div v-else class="overflow-x-auto">
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
      </div>
    </template>
  </SettingsLayout>
</template>
