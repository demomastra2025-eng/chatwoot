<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';

import CaptainObservabilityAPI from 'dashboard/api/captain/observability';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import EventDetailsDialog from './EventDetailsDialog.vue';

const { t, locale } = useI18n();

const events = ref([]);
const meta = ref({ count: 0, current_page: 1, per_page: 25 });
const isLoading = ref(false);
const deletingEventId = ref(null);
const isClearing = ref(false);
const selectedEvent = ref(null);
const detailsDialogRef = ref(null);
const deleteDialogRef = ref(null);
const clearDialogRef = ref(null);
let latestFetchId = 0;

const currentPage = computed(() => Number(meta.value.current_page || 1));
const totalCount = computed(() => Number(meta.value.count || 0));
const itemsPerPage = computed(() => Number(meta.value.per_page || 25));

const statusClass = event => {
  if (event.error || event.status === 'error' || event.status === 'failed') {
    return 'bg-n-ruby-9';
  }
  if (event.blocked || event.status === 'blocked') return 'bg-n-amber-9';
  return 'bg-n-teal-9';
};

const eventTitle = event =>
  String(
    event.event_name || event.reason || t('CAPTAIN.OBSERVABILITY.SIMPLE.EVENT')
  )
    .replace(/[._-]+/g, ' ')
    .replace(/\b\w/g, character => character.toUpperCase());

const eventSubtitle = event =>
  [event.model, event.tool_name].filter(Boolean).join(' · ') ||
  t('CAPTAIN.OBSERVABILITY.SIMPLE.NO_MODEL');

const formatTimestamp = value => {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '—';

  return new Intl.DateTimeFormat(locale.value, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
};

const fetchEvents = async (page = currentPage.value) => {
  latestFetchId += 1;
  const fetchId = latestFetchId;
  isLoading.value = true;
  try {
    const response = await CaptainObservabilityAPI.get({
      feature: 'assistant',
      page,
      per_page: itemsPerPage.value,
    });
    if (fetchId !== latestFetchId) return;

    const data = response?.data || response || {};
    const nextEvents = data.payload || [];
    const nextMeta = data.meta || {
      count: 0,
      current_page: page,
      per_page: 25,
    };
    const perPage = Number(nextMeta.per_page || 25);
    const lastPage = Math.max(
      1,
      Math.ceil(Number(nextMeta.count || 0) / perPage)
    );

    if (!nextEvents.length && page > lastPage) {
      await fetchEvents(lastPage);
      return;
    }

    events.value = nextEvents;
    meta.value = nextMeta;
  } catch {
    if (fetchId === latestFetchId) {
      useAlert(t('CAPTAIN.OBSERVABILITY.SIMPLE.LOAD_ERROR'));
    }
  } finally {
    if (fetchId === latestFetchId) isLoading.value = false;
  }
};

const openDetails = event => detailsDialogRef.value?.open(event);

const openDeleteDialog = event => {
  selectedEvent.value = event;
  deleteDialogRef.value?.open();
};

const deleteEvent = async () => {
  if (!selectedEvent.value) return;

  latestFetchId += 1;
  isLoading.value = false;
  deletingEventId.value = selectedEvent.value.id;
  try {
    await CaptainObservabilityAPI.deleteEvent(selectedEvent.value.id);
    deleteDialogRef.value?.close();
    selectedEvent.value = null;
    const targetPage =
      events.value.length === 1 && currentPage.value > 1
        ? currentPage.value - 1
        : currentPage.value;
    await fetchEvents(targetPage);
    useAlert(t('CAPTAIN.OBSERVABILITY.SIMPLE.DELETE_SUCCESS'));
  } catch {
    useAlert(t('CAPTAIN.OBSERVABILITY.SIMPLE.DELETE_ERROR'));
  } finally {
    deletingEventId.value = null;
  }
};

const clearEvents = async () => {
  latestFetchId += 1;
  isLoading.value = false;
  isClearing.value = true;
  try {
    await CaptainObservabilityAPI.clear();
    clearDialogRef.value?.close();
    await fetchEvents(1);
    useAlert(t('CAPTAIN.OBSERVABILITY.SIMPLE.CLEAR_SUCCESS'));
  } catch {
    useAlert(t('CAPTAIN.OBSERVABILITY.SIMPLE.CLEAR_ERROR'));
  } finally {
    isClearing.value = false;
  }
};

onMounted(() => fetchEvents(1));
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.OBSERVABILITY.TITLE')"
    :button-label="events.length ? t('CAPTAIN.OBSERVABILITY.SIMPLE.CLEAR') : ''"
    button-icon="i-lucide-trash-2"
    :is-fetching="isLoading"
    :is-empty="!events.length"
    :current-page="currentPage"
    :total-count="totalCount"
    :items-per-page="itemsPerPage"
    :show-assistant-switcher="false"
    :show-know-more="false"
    @click="clearDialogRef?.open()"
    @update:current-page="fetchEvents"
  >
    <template #search>
      <Button
        :label="t('CAPTAIN.OBSERVABILITY.SIMPLE.REFRESH')"
        icon="i-lucide-refresh-cw"
        variant="outline"
        color="slate"
        size="sm"
        :disabled="isLoading"
        @click="fetchEvents()"
      />
    </template>

    <template #emptyState>
      <div
        class="flex h-full min-h-80 flex-col items-center justify-center gap-3 text-center"
      >
        <div
          class="flex size-12 items-center justify-center rounded-xl bg-n-alpha-2"
        >
          <span class="i-lucide-scroll-text size-6 text-n-slate-10" />
        </div>
        <div>
          <h2 class="text-base font-medium text-n-slate-12">
            {{ t('CAPTAIN.OBSERVABILITY.SIMPLE.EMPTY_TITLE') }}
          </h2>
          <p class="mt-1 text-sm text-n-slate-11">
            {{ t('CAPTAIN.OBSERVABILITY.SIMPLE.EMPTY_DESCRIPTION') }}
          </p>
        </div>
      </div>
    </template>

    <template #body>
      <div class="overflow-hidden rounded-xl border border-n-weak bg-n-alpha-1">
        <div
          v-for="event in events"
          :key="event.id"
          class="flex items-center gap-3 border-b border-n-weak px-4 py-3 last:border-b-0 hover:bg-n-alpha-2"
        >
          <span
            class="size-2 shrink-0 rounded-full"
            :class="statusClass(event)"
          />
          <button
            class="min-w-0 flex-1 text-left"
            type="button"
            @click="openDetails(event)"
          >
            <span class="block truncate text-sm font-medium text-n-slate-12">
              {{ eventTitle(event) }}
            </span>
            <span class="mt-0.5 block truncate text-xs text-n-slate-10">
              {{ eventSubtitle(event) }}
            </span>
          </button>
          <span class="hidden shrink-0 text-xs text-n-slate-10 sm:block">
            {{ formatTimestamp(event.created_at) }}
          </span>
          <Button
            icon="i-lucide-trash-2"
            variant="ghost"
            color="slate"
            size="xs"
            :is-loading="deletingEventId === event.id"
            :aria-label="t('CAPTAIN.OBSERVABILITY.SIMPLE.DELETE')"
            @click="openDeleteDialog(event)"
          />
        </div>
      </div>
    </template>
  </PageLayout>

  <EventDetailsDialog ref="detailsDialogRef" />

  <Dialog
    ref="deleteDialogRef"
    type="alert"
    :title="t('CAPTAIN.OBSERVABILITY.SIMPLE.DELETE_TITLE')"
    :description="t('CAPTAIN.OBSERVABILITY.SIMPLE.DELETE_DESCRIPTION')"
    :confirm-button-label="t('CAPTAIN.OBSERVABILITY.SIMPLE.DELETE')"
    :is-loading="Boolean(deletingEventId)"
    @confirm="deleteEvent"
  />

  <Dialog
    ref="clearDialogRef"
    type="alert"
    :title="t('CAPTAIN.OBSERVABILITY.SIMPLE.CLEAR_TITLE')"
    :description="t('CAPTAIN.OBSERVABILITY.SIMPLE.CLEAR_DESCRIPTION')"
    :confirm-button-label="t('CAPTAIN.OBSERVABILITY.SIMPLE.CLEAR')"
    :is-loading="isClearing"
    @confirm="clearEvents"
  />
</template>
