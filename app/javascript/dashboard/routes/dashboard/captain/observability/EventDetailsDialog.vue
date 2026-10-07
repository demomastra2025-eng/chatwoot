<script setup>
/* eslint-disable no-use-before-define */
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const { t, locale } = useI18n();
const dialogRef = ref(null);
const event = ref(null);

const summary = computed(() => {
  if (!event.value) return [];

  return [
    [t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.STATUS'), event.value.status],
    [t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.MODEL'), event.value.model],
    [t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.PROVIDER'), event.value.provider],
    [t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.TOOL'), event.value.tool_name],
    [
      t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.DURATION'),
      formatDuration(event.value.duration_ms),
    ],
    [
      t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.TOKENS'),
      event.value.total_tokens,
    ],
    [
      t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.COST'),
      formatCost(event.value.estimated_cost),
    ],
    [
      t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.TIME'),
      formatTimestamp(event.value.created_at),
    ],
  ].filter(
    ([, value]) => value !== null && value !== undefined && value !== ''
  );
});

const formattedDetails = computed(() => {
  if (!event.value?.details || !Object.keys(event.value.details).length) {
    return '';
  }
  return JSON.stringify(event.value.details, null, 2);
});

const formatDuration = value => {
  if (value === null || value === undefined) return null;
  return `${Number(value).toLocaleString(locale.value)} ms`;
};

const formatCost = value => {
  if (value === null || value === undefined) return null;
  return new Intl.NumberFormat(locale.value, {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: 6,
  }).format(Number(value));
};

const formatTimestamp = value => {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat(locale.value, {
    dateStyle: 'medium',
    timeStyle: 'medium',
  }).format(date);
};

const title = computed(() =>
  String(event.value?.event_name || t('CAPTAIN.OBSERVABILITY.SIMPLE.EVENT'))
    .replace(/[._-]+/g, ' ')
    .replace(/\b\w/g, character => character.toUpperCase())
);

const open = selectedEvent => {
  event.value = selectedEvent;
  dialogRef.value?.open();
};

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    :title="title"
    :show-confirm-button="false"
    show-close-button
    :close-button-label="t('GENERAL.CLOSE')"
    overflow-y-auto
    width="2xl"
  >
    <div v-if="event" class="space-y-5">
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div
          v-for="([label, value], index) in summary"
          :key="index"
          class="rounded-lg bg-n-alpha-2 px-3 py-2"
        >
          <div class="text-xs text-n-slate-10">{{ label }}</div>
          <div class="mt-1 break-words text-sm text-n-slate-12">
            {{ value }}
          </div>
        </div>
      </div>

      <div
        v-if="event.error"
        class="rounded-lg bg-n-ruby-3 px-3 py-2 text-sm text-n-ruby-11"
      >
        {{ event.reason || t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.ERROR') }}
      </div>

      <div v-if="formattedDetails">
        <h3 class="mb-2 text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.DATA') }}
        </h3>
        <pre
          class="max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-n-alpha-2 p-3 text-xs text-n-slate-11"
        ><code>{{ formattedDetails }}</code></pre>
      </div>
    </div>
  </Dialog>
</template>
