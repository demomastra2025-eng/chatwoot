<!-- eslint-disable vue/html-closing-bracket-newline @intlify/vue-i18n/no-raw-text -->
<script setup>
/* eslint-disable no-alert */
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';

import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import { useAccount } from 'dashboard/composables/useAccount';
import { useAlert } from 'dashboard/composables';
import { useContentStore } from 'dashboard/stores/content';
import { buildPostizPostPayload } from './postizPayload';
import {
  addMonths,
  buildCalendarDays,
  channelAvatar,
  channelForPost,
  channelName,
  channelProvider,
  filterPosts,
  flattenAnalytics,
  formatDateTime,
  formatMonth,
  monthRange,
  normalizeMedia,
  postDateValue,
  postStatus,
  postTitle,
  providerOptions,
  statusClass,
  summarizePosts,
} from './smmHelpers';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const { currentAccount } = useAccount();
const contentStore = useContentStore();

const settingsForm = reactive({
  accessToken: '',
  organizationId: '',
  defaultTimezone: '',
});

const composer = reactive({
  content: '',
  date: '',
  type: 'schedule',
  integrationId: '',
  media: [],
  shortLink: false,
  tags: [],
  settings: {},
});

const postFilters = reactive({
  query: '',
  status: 'all',
  channelId: 'all',
});

const analyticsForm = reactive({
  integrationId: '',
  postId: '',
  date: '30',
});

const mediaUrl = ref('');
const uploadedMedia = ref([]);
const analyticsResult = ref(null);
const analyticsScope = ref('channel');
const missingResult = ref(null);
const slotResult = ref(null);
const selectedDateKey = ref(new Date().toISOString().slice(0, 10));
const calendarAnchor = ref(new Date());
const isSavingSettings = ref(false);
const isTestingConnection = ref(false);
const isOpeningProvider = ref('');
const isDeletingChannel = ref('');

const section = computed(() => route.meta.section || 'calendar');
const accountId = computed(
  () => route.params.accountId || currentAccount.value?.id
);

const posts = computed(() => contentStore.posts);
const channels = computed(() => contentStore.channels);
const isConnected = computed(() => contentStore.isConnected);
const postSummary = computed(() => summarizePosts(posts.value));
const calendarDays = computed(() =>
  buildCalendarDays(calendarAnchor.value, posts.value)
);
const selectedDay = computed(() =>
  calendarDays.value.find(day => day.key === selectedDateKey.value)
);
const selectedDayPosts = computed(() => selectedDay.value?.posts || []);
const filteredPosts = computed(() => filterPosts(posts.value, postFilters));
const analyticsMetrics = computed(() =>
  flattenAnalytics(analyticsResult.value)
);
const activeChannelOptions = computed(() =>
  channels.value.map(channel => ({
    id: channel.id,
    name: channelName(channel),
    provider: channelProvider(channel),
    avatar: channelAvatar(channel),
    disabled: channel.disabled === true,
  }))
);
const canCreatePost = computed(
  () =>
    composer.content.trim() &&
    composer.integrationId &&
    (composer.type !== 'schedule' || composer.date)
);

const statusOptions = [
  { id: 'all', label: 'Все статусы' },
  { id: 'queue', label: 'Запланировано' },
  { id: 'published', label: 'Опубликовано' },
  { id: 'draft', label: 'Черновики' },
  { id: 'error', label: 'Ошибки' },
];

const analyticsRanges = [
  { id: '7', label: '7 дней' },
  { id: '30', label: '30 дней' },
  { id: '90', label: '90 дней' },
];

const weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

const ui = {
  analytics: {
    channel: 'Соцсеть',
    empty: '{{ ui.analytics.empty }}',
    post: 'Пост',
    selectPost: 'Выберите пост',
  },
  calendar: {
    selectedDayPosts: 'Посты выбранного дня',
  },
  channel: {
    active: 'Активен',
    connectDescription: 'Подключите аккаунты соцсетей через Postiz OAuth.',
    connectTitle: 'Подключить соцсеть',
    disabled: 'Отключен',
  },
  composer: {
    attachMedia: '{{ ui.composer.attachMedia }}',
  },
  filters: {
    allChannels: 'Все соц.сети',
    search: 'Поиск по тексту',
  },
  media: {
    empty:
      'Загрузите файл или URL, чтобы собрать медиабиблиотеку для текущего поста.',
    sessionDescription:
      'Postiz Public API возвращает файл сразу; здесь можно прикрепить его к новому посту.',
    sessionTitle: '{{ ui.media.sessionTitle }}',
    uploadFile: 'Загрузить файл',
  },
  missingContent: 'Missing content',
  morePosts: count => `+${count} ещё`,
  stats: {
    channels: 'Соц.сети',
    posts: 'Посты месяца',
    published: 'Опубликовано',
    scheduled: 'Запланировано',
  },
};

const syncSettingsForm = () => {
  const settings = contentStore.connection?.settings || {};
  settingsForm.organizationId =
    settings.organizationId || settings.organization_id || '';
  settingsForm.defaultTimezone =
    settings.defaultTimezone || settings.default_timezone || '';
};

const loadConnection = async () => {
  await contentStore.fetchConnection();
  syncSettingsForm();
};

const loadChannels = async () => {
  if (!isConnected.value) return;
  await contentStore.fetchChannels();
  if (!composer.integrationId && activeChannelOptions.value[0]) {
    composer.integrationId = activeChannelOptions.value[0].id;
  }
  if (!analyticsForm.integrationId && activeChannelOptions.value[0]) {
    analyticsForm.integrationId = activeChannelOptions.value[0].id;
  }
};

const loadPosts = async () => {
  if (!isConnected.value) return;
  await contentStore.fetchPosts(monthRange(calendarAnchor.value));
};

const refreshCurrentSection = async () => {
  try {
    if (section.value === 'channels') await loadChannels();
    if (['calendar', 'posts', 'analytics'].includes(section.value))
      await loadPosts();
    if (['calendar', 'posts', 'channels', 'analytics'].includes(section.value))
      await loadChannels();
  } catch {
    // The store keeps the user-facing error state.
  }
};

const saveSettings = async () => {
  isSavingSettings.value = true;
  try {
    await contentStore.saveConnection({
      access_token: settingsForm.accessToken,
      settings: {
        organization_id: settingsForm.organizationId,
        default_timezone: settingsForm.defaultTimezone,
      },
      status: 'enabled',
    });
    settingsForm.accessToken = '';
    useAlert(t('SMM.SETTINGS.SAVED'));
    await loadChannels();
    return true;
  } catch {
    useAlert(t('SMM.SETTINGS.SAVE_FAILED'));
    return false;
  } finally {
    isSavingSettings.value = false;
  }
};

const testConnection = async () => {
  if (
    !contentStore.connection?.tokenConfigured &&
    !settingsForm.accessToken.trim()
  ) {
    useAlert(t('SMM.SETTINGS.TEST_FAILED'));
    return;
  }

  isTestingConnection.value = true;
  try {
    if (settingsForm.accessToken.trim()) {
      const saved = await saveSettings();
      if (!saved) return;
    }

    const result = await contentStore.testConnection();
    useAlert(
      result.connected
        ? t('SMM.SETTINGS.TEST_OK')
        : t('SMM.SETTINGS.TEST_FAILED')
    );
  } catch {
    useAlert(t('SMM.SETTINGS.TEST_FAILED'));
  } finally {
    isTestingConnection.value = false;
  }
};

const connectProvider = async (provider, refresh) => {
  isOpeningProvider.value = provider;
  try {
    await contentStore.openOAuth(provider, refresh);
  } catch {
    useAlert(t('SMM.CHANNELS.OAUTH_FAILED'));
  } finally {
    isOpeningProvider.value = '';
  }
};

const deleteChannel = async channel => {
  if (
    !window.confirm(
      `Удалить соцсеть ${channelName(channel)}? Запланированные посты Postiz для этой соцсети тоже могут быть удалены.`
    )
  )
    return;

  isDeletingChannel.value = channel.id;
  try {
    await contentStore.deleteChannel(channel.id);
    useAlert('Соцсеть удалена');
    await loadPosts();
  } catch {
    useAlert('Не удалось удалить соцсеть');
  } finally {
    isDeletingChannel.value = '';
  }
};

const findSlot = async channel => {
  try {
    slotResult.value = {
      channel: channelName(channel),
      result: await contentStore.findChannelSlot(channel.id),
    };
    useAlert('Ближайший слот найден');
  } catch {
    useAlert('Не удалось найти слот Postiz');
  }
};

const createPost = async () => {
  if (!canCreatePost.value) {
    useAlert(t('SMM.COMPOSER.REQUIRED'));
    return;
  }

  try {
    await contentStore.createPost(buildPostizPostPayload(composer));
    composer.content = '';
    composer.media = [];
    useAlert(t('SMM.COMPOSER.CREATED'));
    await loadPosts();
  } catch {
    useAlert(t('SMM.COMPOSER.CREATE_FAILED'));
  }
};

const deletePost = async post => {
  if (!window.confirm('Удалить этот пост из Postiz?')) return;

  try {
    await contentStore.deletePost(post.id);
    useAlert('Пост удалён');
  } catch {
    useAlert('Не удалось удалить пост');
  }
};

const updatePostStatus = async (post, status) => {
  try {
    await contentStore.updatePostStatus(post.id, status);
    useAlert('Статус поста обновлён');
    await loadPosts();
  } catch {
    useAlert('Не удалось обновить статус поста');
  }
};

const checkMissing = async post => {
  try {
    missingResult.value = {
      postId: post.id,
      title: postTitle(post),
      result: await contentStore.checkPostMissing(post.id),
    };
    useAlert('Проверка контента выполнена');
  } catch {
    useAlert('Не удалось проверить недостающий контент');
  }
};

const uploadFile = async event => {
  const file = event.target.files?.[0];
  if (!file) return;

  try {
    const media = normalizeMedia(await contentStore.uploadMedia(file));
    if (media) uploadedMedia.value = [media, ...uploadedMedia.value];
    useAlert(t('SMM.MEDIA.UPLOADED'));
  } catch {
    useAlert(t('SMM.MEDIA.UPLOAD_FAILED'));
  } finally {
    event.target.value = '';
  }
};

const uploadFromUrl = async () => {
  if (!mediaUrl.value) return;

  try {
    const media = normalizeMedia(
      await contentStore.uploadMediaFromUrl(mediaUrl.value)
    );
    if (media) uploadedMedia.value = [media, ...uploadedMedia.value];
    mediaUrl.value = '';
    useAlert(t('SMM.MEDIA.UPLOADED'));
  } catch {
    useAlert(t('SMM.MEDIA.UPLOAD_FAILED'));
  }
};

const attachMedia = media => {
  if (composer.media.some(item => item.id === media.id)) return;
  composer.media.push(media);
};

const detachMedia = media => {
  composer.media = composer.media.filter(item => item.id !== media.id);
};

const loadAnalytics = async (scope = analyticsScope.value) => {
  const params = { date: analyticsForm.date };
  if (scope === 'post') {
    if (!analyticsForm.postId) return;
    params.post_id = analyticsForm.postId;
  } else {
    if (!analyticsForm.integrationId) return;
    params.integration = analyticsForm.integrationId;
  }

  analyticsScope.value = scope;
  try {
    analyticsResult.value = await contentStore.fetchAnalytics(params);
  } catch {
    useAlert(t('SMM.ANALYTICS.LOAD_FAILED'));
  }
};

const loadPostAnalytics = async post => {
  analyticsForm.postId = post.id;
  await loadAnalytics('post');
  if (section.value !== 'analytics') {
    router.push({
      name: 'smm_analytics',
      params: { accountId: accountId.value },
    });
  }
};

const selectDay = day => {
  selectedDateKey.value = day.key;
  composer.date = `${day.key}T09:00`;
};

const shiftMonth = async amount => {
  calendarAnchor.value = addMonths(calendarAnchor.value, amount);
  selectedDateKey.value = calendarAnchor.value.toISOString().slice(0, 10);
  await loadPosts();
};

const goToSettings = () =>
  router.push({
    name: 'smm_settings',
    params: { accountId: accountId.value },
  });

onMounted(async () => {
  await loadConnection();
  await refreshCurrentSection();
});

watch(section, refreshCurrentSection);
</script>

<template>
  <main
    class="flex h-full min-h-0 flex-col overflow-y-auto bg-n-background p-6"
  >
    <header
      class="mb-5 rounded-3xl border border-n-weak bg-gradient-to-br from-n-solid-1 to-n-alpha-2 p-5"
    >
      <div
        class="grid gap-3 md:grid-cols-2 xl:grid-cols-[repeat(4,minmax(0,1fr))_auto]"
      >
        <div class="rounded-2xl border border-n-weak bg-n-background p-4">
          <p class="text-xs text-n-slate-10">{{ ui.stats.channels }}</p>
          <p class="mt-1 text-2xl font-semibold text-n-slate-12">
            {{ channels.length }}
          </p>
        </div>
        <div class="rounded-2xl border border-n-weak bg-n-background p-4">
          <p class="text-xs text-n-slate-10">{{ ui.stats.posts }}</p>
          <p class="mt-1 text-2xl font-semibold text-n-slate-12">
            {{ postSummary.total }}
          </p>
        </div>
        <div class="rounded-2xl border border-n-weak bg-n-background p-4">
          <p class="text-xs text-n-slate-10">{{ ui.stats.scheduled }}</p>
          <p class="mt-1 text-2xl font-semibold text-n-amber-11">
            {{ postSummary.scheduled }}
          </p>
        </div>
        <div class="rounded-2xl border border-n-weak bg-n-background p-4">
          <p class="text-xs text-n-slate-10">{{ ui.stats.published }}</p>
          <p class="mt-1 text-2xl font-semibold text-n-teal-11">
            {{ postSummary.published }}
          </p>
        </div>
        <div
          class="flex items-center rounded-2xl border border-n-weak bg-n-background p-4"
        >
          <Button
            v-if="!isConnected"
            :label="t('SMM.CONNECT_POSTIZ')"
            icon="i-lucide-key-round"
            @click="goToSettings"
          />
          <Button
            v-else
            :label="t('SMM.REFRESH')"
            icon="i-lucide-refresh-cw"
            faded
            @click="refreshCurrentSection"
          />
        </div>
      </div>
    </header>

    <div
      v-if="contentStore.ui.error"
      class="mb-4 rounded-xl border border-n-ruby-6 bg-n-ruby-3 p-4 text-sm text-n-ruby-11"
    >
      {{ contentStore.ui.error }}
    </div>

    <section
      v-if="!isConnected && section !== 'settings'"
      class="rounded-3xl border border-n-weak bg-n-solid-1 p-10 text-center"
    >
      <div
        class="mx-auto mb-4 flex size-14 items-center justify-center rounded-2xl bg-n-brand/10 text-n-brand"
      >
        <span class="i-lucide-key-round text-3xl" />
      </div>
      <h2 class="text-xl font-semibold text-n-slate-12">
        {{ t('SMM.EMPTY_CONNECTION_TITLE') }}
      </h2>
      <p class="mx-auto mt-2 max-w-xl text-sm text-n-slate-11">
        {{ t('SMM.EMPTY_CONNECTION_DESCRIPTION') }}
      </p>
      <Button
        class="mt-5"
        :label="t('SMM.OPEN_SETTINGS')"
        @click="goToSettings"
      />
    </section>

    <section
      v-else-if="section === 'calendar'"
      class="grid gap-4 xl:grid-cols-[1.5fr_0.8fr]"
    >
      <div class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
        <div
          class="mb-4 flex flex-col gap-3 md:flex-row md:items-center md:justify-between"
        >
          <div>
            <h2 class="text-lg font-semibold text-n-slate-12">
              {{ t('SMM.CALENDAR.TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11">
              {{ t('SMM.CALENDAR.DESCRIPTION') }}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <Button
              icon="i-lucide-chevron-left"
              faded
              @click="shiftMonth(-1)"
            />
            <span
              class="min-w-40 text-center text-sm font-semibold text-n-slate-12"
            >
              {{ formatMonth(calendarAnchor) }}
            </span>
            <Button
              icon="i-lucide-chevron-right"
              faded
              @click="shiftMonth(1)"
            />
            <Spinner v-if="contentStore.ui.isLoadingPosts" />
          </div>
        </div>

        <div
          class="grid grid-cols-7 gap-2 text-center text-xs font-medium text-n-slate-10"
        >
          <span v-for="dayName in weekdays" :key="dayName">{{ dayName }}</span>
        </div>
        <div class="mt-2 grid grid-cols-1 gap-2 md:grid-cols-7">
          <button
            v-for="day in calendarDays"
            :key="day.key"
            class="min-h-32 rounded-2xl border p-3 text-left transition hover:border-n-brand/40 hover:bg-n-alpha-2"
            :class="[
              day.key === selectedDateKey
                ? 'border-n-brand bg-n-brand/5'
                : 'border-n-weak bg-n-background',
              !day.inMonth && 'opacity-50',
            ]"
            type="button"
            @click="selectDay(day)"
          >
            <div class="mb-2 flex items-center justify-between">
              <span class="text-sm font-semibold text-n-slate-12">{{
                day.label
              }}</span>
              <span
                v-if="day.posts.length"
                class="rounded-full bg-n-brand/10 px-2 py-0.5 text-xs text-n-brand"
              >
                {{ day.posts.length }}
              </span>
            </div>
            <div class="space-y-1">
              <div
                v-for="post in day.posts.slice(0, 3)"
                :key="post.id"
                class="truncate rounded-lg bg-n-alpha-2 px-2 py-1 text-xs text-n-slate-11"
              >
                {{ postTitle(post) }}
              </div>
              <div v-if="day.posts.length > 3" class="text-xs text-n-slate-10">
                {{ ui.morePosts(day.posts.length - 3) }}
              </div>
            </div>
          </button>
        </div>
      </div>

      <aside class="space-y-4">
        <div class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
          <h3 class="font-semibold text-n-slate-12">{{ selectedDateKey }}</h3>
          <p class="text-sm text-n-slate-11">
            {{ ui.calendar.selectedDayPosts }}
          </p>
          <div class="mt-4 space-y-3">
            <article
              v-for="post in selectedDayPosts"
              :key="post.id"
              class="rounded-2xl border border-n-weak bg-n-background p-3"
            >
              <div class="mb-2 flex items-start justify-between gap-2">
                <p class="line-clamp-2 text-sm font-medium text-n-slate-12">
                  {{ postTitle(post) }}
                </p>
                <span
                  class="rounded-full px-2 py-0.5 text-xs"
                  :class="statusClass(postStatus(post))"
                >
                  {{ postStatus(post) }}
                </span>
              </div>
              <p class="text-xs text-n-slate-10">
                {{ formatDateTime(postDateValue(post)) }}
              </p>
            </article>
            <p v-if="!selectedDayPosts.length" class="text-sm text-n-slate-11">
              {{ t('SMM.CALENDAR.EMPTY') }}
            </p>
          </div>
        </div>

        <div class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
          <h3 class="text-lg font-semibold text-n-slate-12">
            {{ t('SMM.COMPOSER.TITLE') }}
          </h3>
          <p class="mb-4 text-sm text-n-slate-11">
            {{ t('SMM.COMPOSER.DESCRIPTION') }}
          </p>
          <div class="space-y-3">
            <select
              v-model="composer.integrationId"
              class="h-10 w-full rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
            >
              <option value="">{{ t('SMM.COMPOSER.SELECT_CHANNEL') }}</option>
              <option
                v-for="channel in activeChannelOptions"
                :key="channel.id"
                :value="channel.id"
              >
                {{ channel.name }}
              </option>
            </select>
            <select
              v-model="composer.type"
              class="h-10 w-full rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
            >
              <option value="schedule">
                {{ t('SMM.COMPOSER.TYPE_SCHEDULE') }}
              </option>
              <option value="draft">{{ t('SMM.COMPOSER.TYPE_DRAFT') }}</option>
              <option value="now">{{ t('SMM.COMPOSER.TYPE_NOW') }}</option>
            </select>
            <Input
              v-model="composer.date"
              type="datetime-local"
              :placeholder="t('SMM.COMPOSER.DATE')"
            />
            <TextArea
              v-model="composer.content"
              :placeholder="t('SMM.COMPOSER.TEXT_PLACEHOLDER')"
              rows="6"
            />
            <div
              v-if="uploadedMedia.length"
              class="rounded-2xl border border-n-weak bg-n-background p-3"
            >
              <p class="mb-2 text-xs font-medium text-n-slate-10">
                {{ ui.composer.attachMedia }}
              </p>
              <div class="flex flex-wrap gap-2">
                <button
                  v-for="media in uploadedMedia"
                  :key="media.id"
                  class="rounded-lg border px-2 py-1 text-xs"
                  :class="
                    composer.media.some(item => item.id === media.id)
                      ? 'border-n-brand bg-n-brand/10 text-n-brand'
                      : 'border-n-weak text-n-slate-11'
                  "
                  type="button"
                  @click="
                    composer.media.some(item => item.id === media.id)
                      ? detachMedia(media)
                      : attachMedia(media)
                  "
                >
                  {{ media.name }}
                </button>
              </div>
            </div>
            <Button
              :label="t('SMM.COMPOSER.CREATE')"
              :disabled="!canCreatePost"
              :is-loading="contentStore.ui.isMutatingPost"
              @click="createPost"
            />
          </div>
        </div>
      </aside>
    </section>

    <section
      v-else-if="section === 'posts'"
      class="rounded-3xl border border-n-weak bg-n-solid-1 p-5"
    >
      <div
        class="mb-4 flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between"
      >
        <div>
          <h2 class="text-lg font-semibold text-n-slate-12">
            {{ t('SMM.POSTS.TITLE') }}
          </h2>
          <p class="text-sm text-n-slate-11">
            {{ t('SMM.POSTS.DESCRIPTION') }}
          </p>
        </div>
        <div class="grid gap-2 md:grid-cols-3">
          <Input v-model="postFilters.query" :placeholder="ui.filters.search" />
          <select
            v-model="postFilters.status"
            class="h-10 rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
          >
            <option
              v-for="status in statusOptions"
              :key="status.id"
              :value="status.id"
            >
              {{ status.label }}
            </option>
          </select>
          <select
            v-model="postFilters.channelId"
            class="h-10 rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
          >
            <option value="all">{{ ui.filters.allChannels }}</option>
            <option
              v-for="channel in activeChannelOptions"
              :key="channel.id"
              :value="channel.id"
            >
              {{ channel.name }}
            </option>
          </select>
        </div>
      </div>

      <div class="space-y-3">
        <article
          v-for="post in filteredPosts"
          :key="post.id"
          class="rounded-2xl border border-n-weak bg-n-background p-4"
        >
          <div
            class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between"
          >
            <div class="min-w-0">
              <div class="mb-2 flex flex-wrap items-center gap-2">
                <span
                  class="rounded-full px-2 py-1 text-xs font-medium"
                  :class="statusClass(postStatus(post))"
                >
                  {{ postStatus(post) }}
                </span>
                <span class="text-xs text-n-slate-10">{{
                  formatDateTime(postDateValue(post))
                }}</span>
                <span class="text-xs text-n-slate-10">{{
                  channelName(channelForPost(post, channels) || {})
                }}</span>
              </div>
              <p class="whitespace-pre-wrap text-sm text-n-slate-12">
                {{ postTitle(post) }}
              </p>
            </div>
            <div class="flex flex-wrap gap-2 lg:justify-end">
              <Button
                label="Аналитика"
                icon="i-lucide-chart-no-axes-combined"
                sm
                faded
                @click="loadPostAnalytics(post)"
              />
              <Button
                label="Missing"
                icon="i-lucide-file-question"
                sm
                faded
                @click="checkMissing(post)"
              />
              <Button
                v-if="postStatus(post) !== 'draft'"
                label="В черновик"
                sm
                faded
                @click="updatePostStatus(post, 'draft')"
              />
              <Button
                v-if="postStatus(post) === 'draft'"
                label="В расписание"
                sm
                faded
                @click="updatePostStatus(post, 'schedule')"
              />
              <Button
                label="Удалить"
                icon="i-lucide-trash-2"
                sm
                ruby
                outline
                @click="deletePost(post)"
              />
            </div>
          </div>
        </article>
      </div>
      <p
        v-if="!filteredPosts.length && !contentStore.ui.isLoadingPosts"
        class="mt-4 text-sm text-n-slate-11"
      >
        {{ t('SMM.POSTS.EMPTY') }}
      </p>

      <div
        v-if="missingResult"
        class="mt-4 rounded-2xl border border-n-weak bg-n-background p-4"
      >
        <p class="text-sm font-semibold text-n-slate-12">
          {{ `${ui.missingContent}: ${missingResult.title}` }}
        </p>
        <div class="mt-2 max-h-64 overflow-auto rounded-xl bg-n-alpha-2 p-3">
          <pre class="text-xs text-n-slate-11">{{ missingResult.result }}</pre>
        </div>
      </div>
    </section>

    <section
      v-else-if="section === 'channels'"
      class="grid gap-4 xl:grid-cols-[1fr_0.8fr]"
    >
      <div class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
        <div class="mb-4 flex items-center justify-between gap-3">
          <div>
            <h2 class="text-lg font-semibold text-n-slate-12">
              {{ t('SMM.CHANNELS.TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11">
              {{ t('SMM.CHANNELS.DESCRIPTION') }}
            </p>
          </div>
          <Spinner v-if="contentStore.ui.isLoadingChannels" />
        </div>
        <div class="grid gap-3 md:grid-cols-2">
          <article
            v-for="channel in channels"
            :key="channel.id"
            class="rounded-2xl border border-n-weak bg-n-background p-4"
          >
            <div class="flex items-start gap-3">
              <img
                v-if="channelAvatar(channel)"
                :src="channelAvatar(channel)"
                class="size-11 rounded-xl object-cover"
                alt=""
              />
              <div
                v-else
                class="flex size-11 items-center justify-center rounded-xl bg-n-brand/10 text-n-brand"
              >
                <span class="i-lucide-radio text-xl" />
              </div>
              <div class="min-w-0 flex-1">
                <p class="truncate font-semibold text-n-slate-12">
                  {{ channelName(channel) }}
                </p>
                <p class="text-sm text-n-slate-11">
                  {{ channelProvider(channel) || 'Postiz' }}
                </p>
                <span
                  class="mt-2 inline-flex rounded-full px-2 py-1 text-xs"
                  :class="
                    channel.disabled
                      ? 'bg-n-ruby-3 text-n-ruby-11'
                      : 'bg-n-teal-3 text-n-teal-11'
                  "
                >
                  {{
                    channel.disabled ? ui.channel.disabled : ui.channel.active
                  }}
                </span>
              </div>
            </div>
            <div class="mt-4 flex flex-wrap gap-2">
              <Button label="Найти слот" sm faded @click="findSlot(channel)" />
              <Button
                label="Обновить OAuth"
                sm
                faded
                @click="connectProvider(channelProvider(channel), channel.id)"
              />
              <Button
                label="Удалить"
                sm
                ruby
                outline
                :is-loading="isDeletingChannel === channel.id"
                @click="deleteChannel(channel)"
              />
            </div>
          </article>
        </div>
        <p
          v-if="!channels.length && !contentStore.ui.isLoadingChannels"
          class="text-sm text-n-slate-11"
        >
          {{ t('SMM.CHANNELS.EMPTY') }}
        </p>
        <div
          v-if="slotResult"
          class="mt-4 rounded-2xl border border-n-weak bg-n-background p-4 text-sm text-n-slate-11"
        >
          <span class="font-semibold text-n-slate-12">{{
            `${slotResult.channel}:`
          }}</span>
          {{
            slotResult.result.date ||
            slotResult.result.slot ||
            slotResult.result
          }}
        </div>
      </div>

      <div class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
        <h3 class="text-lg font-semibold text-n-slate-12">
          {{ ui.channel.connectTitle }}
        </h3>
        <p class="mb-4 text-sm text-n-slate-11">
          {{ ui.channel.connectDescription }}
        </p>
        <div class="grid gap-3 sm:grid-cols-2">
          <button
            v-for="provider in providerOptions"
            :key="provider.id"
            class="flex items-center gap-3 rounded-2xl border border-n-weak bg-n-background p-4 text-left hover:border-n-brand/40 hover:bg-n-alpha-2"
            type="button"
            @click="connectProvider(provider.id)"
          >
            <span
              class="flex size-10 items-center justify-center rounded-xl bg-n-alpha-2 text-n-slate-12"
              :class="provider.icon"
            />
            <span class="font-medium text-n-slate-12">{{
              provider.label
            }}</span>
            <Spinner v-if="isOpeningProvider === provider.id" class="ml-auto" />
          </button>
        </div>
      </div>
    </section>

    <section
      v-else-if="section === 'media'"
      class="grid gap-4 lg:grid-cols-[0.8fr_1.2fr]"
    >
      <div class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
        <h2 class="text-lg font-semibold text-n-slate-12">
          {{ t('SMM.MEDIA.TITLE') }}
        </h2>
        <p class="mb-4 text-sm text-n-slate-11">
          {{ t('SMM.MEDIA.DESCRIPTION') }}
        </p>
        <div class="space-y-4">
          <label
            class="block rounded-2xl border border-dashed border-n-weak bg-n-background p-5 text-center hover:border-n-brand/40"
          >
            <span
              class="i-lucide-upload mx-auto mb-2 block text-2xl text-n-brand"
            />
            <span class="text-sm font-medium text-n-slate-12">{{
              ui.media.uploadFile
            }}</span>
            <input
              class="hidden"
              type="file"
              accept="image/*,video/mp4"
              @change="uploadFile"
            />
          </label>
          <div class="flex gap-2">
            <Input
              v-model="mediaUrl"
              :placeholder="t('SMM.MEDIA.URL_PLACEHOLDER')"
            />
            <Button
              :label="t('SMM.MEDIA.UPLOAD_URL')"
              :is-loading="contentStore.ui.isUploadingMedia"
              @click="uploadFromUrl"
            />
          </div>
        </div>
      </div>

      <div class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
        <div class="mb-4 flex items-center justify-between">
          <div>
            <h3 class="text-lg font-semibold text-n-slate-12">
              {{ ui.media.sessionTitle }}
            </h3>
            <p class="text-sm text-n-slate-11">
              {{ ui.media.sessionDescription }}
            </p>
          </div>
          <span
            class="rounded-full bg-n-alpha-2 px-3 py-1 text-xs text-n-slate-11"
          >
            {{ uploadedMedia.length }}
          </span>
        </div>
        <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          <article
            v-for="media in uploadedMedia"
            :key="media.id"
            class="rounded-2xl border border-n-weak bg-n-background p-3"
          >
            <img
              v-if="media.thumbnail || media.path"
              :src="media.thumbnail || media.path"
              class="mb-3 h-32 w-full rounded-xl object-cover"
              alt=""
            />
            <p class="truncate text-sm font-medium text-n-slate-12">
              {{ media.name }}
            </p>
            <p class="truncate text-xs text-n-slate-10">{{ media.id }}</p>
            <Button
              class="mt-3"
              label="Прикрепить к посту"
              sm
              faded
              @click="attachMedia(media)"
            />
          </article>
        </div>
        <p v-if="!uploadedMedia.length" class="text-sm text-n-slate-11">
          {{ ui.media.empty }}
        </p>
      </div>
    </section>

    <section
      v-else-if="section === 'analytics'"
      class="rounded-3xl border border-n-weak bg-n-solid-1 p-5"
    >
      <div
        class="mb-4 flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between"
      >
        <div>
          <h2 class="text-lg font-semibold text-n-slate-12">
            {{ t('SMM.ANALYTICS.TITLE') }}
          </h2>
          <p class="text-sm text-n-slate-11">
            {{ t('SMM.ANALYTICS.DESCRIPTION') }}
          </p>
        </div>
        <div class="grid gap-2 md:grid-cols-4">
          <select
            v-model="analyticsScope"
            class="h-10 rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
          >
            <option value="channel">{{ ui.analytics.channel }}</option>
            <option value="post">{{ ui.analytics.post }}</option>
          </select>
          <select
            v-if="analyticsScope === 'channel'"
            v-model="analyticsForm.integrationId"
            class="h-10 rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
          >
            <option value="">{{ t('SMM.ANALYTICS.SELECT_CHANNEL') }}</option>
            <option
              v-for="channel in activeChannelOptions"
              :key="channel.id"
              :value="channel.id"
            >
              {{ channel.name }}
            </option>
          </select>
          <select
            v-else
            v-model="analyticsForm.postId"
            class="h-10 rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
          >
            <option value="">{{ ui.analytics.selectPost }}</option>
            <option v-for="post in posts" :key="post.id" :value="post.id">
              {{ postTitle(post) }}
            </option>
          </select>
          <select
            v-model="analyticsForm.date"
            class="h-10 rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
          >
            <option
              v-for="range in analyticsRanges"
              :key="range.id"
              :value="range.id"
            >
              {{ range.label }}
            </option>
          </select>
          <Button
            :label="t('SMM.ANALYTICS.LOAD')"
            :is-loading="contentStore.ui.isLoadingAnalytics"
            @click="loadAnalytics()"
          />
        </div>
      </div>

      <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        <article
          v-for="metric in analyticsMetrics"
          :key="metric.label"
          class="rounded-2xl border border-n-weak bg-n-background p-4"
        >
          <p class="text-sm text-n-slate-10">{{ metric.label }}</p>
          <p class="mt-2 text-2xl font-semibold text-n-slate-12">
            {{ metric.total ?? '—' }}
          </p>
          <p
            v-if="metric.percentageChange !== undefined"
            class="mt-1 text-xs text-n-slate-10"
          >
            {{ `${metric.percentageChange}%` }}
          </p>
          <div
            v-if="metric.points.length"
            class="mt-3 flex h-12 items-end gap-1"
          >
            <span
              v-for="point in metric.points.slice(-12)"
              :key="`${metric.label}-${point.date}`"
              class="w-full rounded-t bg-n-brand/40"
              :style="{
                height: `${Math.max(8, Math.min(48, Number(point.total || point.value || 0)))}px`,
              }"
            />
          </div>
        </article>
      </div>
      <div
        v-if="analyticsResult && !analyticsMetrics.length"
        class="rounded-2xl bg-n-alpha-2 p-4"
      >
        <pre class="text-xs text-n-slate-11">{{ analyticsResult }}</pre>
      </div>
      <p v-if="!analyticsResult" class="text-sm text-n-slate-11">
        {{ ui.analytics.empty }}
      </p>
    </section>

    <section
      v-else-if="section === 'settings'"
      class="grid gap-4 lg:grid-cols-[0.8fr_1.2fr]"
    >
      <div class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
        <h2 class="text-lg font-semibold text-n-slate-12">
          {{ t('SMM.SETTINGS.TITLE') }}
        </h2>
        <p class="mb-4 text-sm text-n-slate-11">
          {{ t('SMM.SETTINGS.DESCRIPTION') }}
        </p>
        <div class="space-y-3">
          <Input
            v-model="settingsForm.accessToken"
            type="password"
            :placeholder="t('SMM.SETTINGS.API_KEY_PLACEHOLDER')"
          />
          <Input
            v-model="settingsForm.organizationId"
            :placeholder="t('SMM.SETTINGS.ORG_PLACEHOLDER')"
          />
          <Input
            v-model="settingsForm.defaultTimezone"
            :placeholder="t('SMM.SETTINGS.TIMEZONE_PLACEHOLDER')"
          />
          <div class="flex flex-wrap gap-2">
            <Button
              :label="t('SMM.SETTINGS.SAVE')"
              :is-loading="isSavingSettings"
              @click="saveSettings"
            />
            <Button
              :label="t('SMM.SETTINGS.TEST')"
              :is-loading="isTestingConnection"
              faded
              @click="testConnection"
            />
          </div>
        </div>
      </div>
      <div class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
        <h3 class="text-lg font-semibold text-n-slate-12">
          {{ t('SMM.SETTINGS.STATUS') }}
        </h3>
        <div class="mt-4 grid gap-3 md:grid-cols-2">
          <div class="rounded-2xl border border-n-weak bg-n-background p-4">
            <p class="text-xs text-n-slate-10">
              {{ t('SMM.SETTINGS.CONNECTED') }}
            </p>
            <p class="mt-1 text-lg font-semibold text-n-slate-12">
              {{
                contentStore.connection?.connected ? t('SMM.YES') : t('SMM.NO')
              }}
            </p>
          </div>
          <div class="rounded-2xl border border-n-weak bg-n-background p-4">
            <p class="text-xs text-n-slate-10">
              {{ t('SMM.SETTINGS.TOKEN_CONFIGURED') }}
            </p>
            <p class="mt-1 text-lg font-semibold text-n-slate-12">
              {{
                contentStore.connection?.tokenConfigured
                  ? t('SMM.YES')
                  : t('SMM.NO')
              }}
            </p>
          </div>
        </div>
        <div class="mt-4 max-h-64 overflow-auto rounded-2xl bg-n-alpha-2 p-4">
          <pre class="text-xs text-n-slate-11">{{
            contentStore.connection
          }}</pre>
        </div>
      </div>
    </section>
  </main>
</template>
