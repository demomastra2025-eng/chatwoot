<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  preview: {
    type: Object,
    default: null,
  },
  stale: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();

const colorClass = computed(() => {
  if (props.stale) return 'border-n-slate-5 bg-n-slate-2 text-n-slate-11';
  if (!props.preview) return 'border-n-slate-5 bg-n-slate-2 text-n-slate-11';
  if (props.preview.deliverable_count > 0) {
    return props.preview.blocked_count > 0
      ? 'border-n-amber-4 bg-n-amber-2 text-n-amber-11'
      : 'border-n-teal-4 bg-n-teal-2 text-n-teal-11';
  }

  return 'border-n-ruby-4 bg-n-ruby-2 text-n-ruby-11';
});

const totalRows = computed(() => {
  if (!props.preview?.totals) return [];

  return Object.entries(props.preview.totals)
    .filter(([, value]) => Number(value) > 0)
    .filter(([key]) => key !== 'deliverable')
    .map(([key, value]) => ({
      key,
      value,
      label: t(`CAMPAIGN.PREVIEW.TOTALS.${key.toUpperCase()}`),
    }));
});

const statusLabel = computed(() => {
  if (props.stale) return t('CAMPAIGN.PREVIEW.STATUS_STALE');
  if (!props.preview) return t('CAMPAIGN.PREVIEW.STATUS_EMPTY');
  if (props.preview.deliverable_count > 0) {
    return props.preview.blocked_count > 0
      ? t('CAMPAIGN.PREVIEW.STATUS_PARTIAL')
      : t('CAMPAIGN.PREVIEW.STATUS_READY');
  }

  return t('CAMPAIGN.PREVIEW.STATUS_BLOCKED');
});
</script>

<template>
  <div
    class="rounded-xl border border-dashed p-3 flex flex-col gap-3"
    :class="colorClass"
  >
    <div class="flex items-start justify-between gap-3">
      <div class="flex flex-col gap-1">
        <h4 class="text-sm font-medium">
          {{ t('CAMPAIGN.PREVIEW.TITLE') }}
        </h4>
        <p class="text-xs opacity-90">
          {{ statusLabel }}
        </p>
      </div>
    </div>

    <div v-if="preview" class="grid grid-cols-3 gap-2 text-xs">
      <div class="rounded-lg bg-n-alpha-1 px-3 py-2">
        <div class="opacity-80">{{ t('CAMPAIGN.PREVIEW.AUDIENCE_SIZE') }}</div>
        <div class="text-sm font-medium">{{ preview.audience_size }}</div>
      </div>
      <div class="rounded-lg bg-n-alpha-1 px-3 py-2">
        <div class="opacity-80">{{ t('CAMPAIGN.PREVIEW.DELIVERABLE') }}</div>
        <div class="text-sm font-medium">{{ preview.deliverable_count }}</div>
      </div>
      <div class="rounded-lg bg-n-alpha-1 px-3 py-2">
        <div class="opacity-80">{{ t('CAMPAIGN.PREVIEW.BLOCKED') }}</div>
        <div class="text-sm font-medium">{{ preview.blocked_count }}</div>
      </div>
    </div>

    <div v-if="preview && totalRows.length" class="flex flex-col gap-1 text-xs">
      <p class="font-medium">
        {{ t('CAMPAIGN.PREVIEW.BLOCKERS_TITLE') }}
      </p>
      <div
        v-for="row in totalRows"
        :key="row.key"
        class="flex items-center justify-between gap-3"
      >
        <span>{{ row.label }}</span>
        <span class="font-medium">{{ row.value }}</span>
      </div>
    </div>
  </div>
</template>
