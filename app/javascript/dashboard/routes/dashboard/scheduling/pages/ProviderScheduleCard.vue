<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  schedule: { type: Object, required: true },
});

const { t } = useI18n();

const checkedMinutesAgo = computed(() => {
  if (!props.schedule?.checkedAt) return null;
  return Math.max(
    0,
    Math.floor((Date.now() - Date.parse(props.schedule.checkedAt)) / 60000)
  );
});
</script>

<template>
  <section
    data-testid="provider-schedule-card"
    class="flex items-center justify-between gap-3 border-b border-n-weak pb-2.5 text-xs text-n-slate-11"
  >
    <span class="inline-flex items-center gap-1.5 font-medium text-n-slate-12">
      <i class="i-lucide-refresh-cw size-3.5 shrink-0 text-n-slate-10" />
      {{ t('SCHEDULING.RESOURCES.PROVIDER_SCHEDULE_TITLE') }}
    </span>
    <span
      v-if="checkedMinutesAgo === null"
      class="truncate text-right text-n-slate-10"
    >
      {{ t('SCHEDULING.RESOURCES.PROVIDER_NOT_LOADED') }}
    </span>
    <span v-else class="truncate text-right text-n-slate-11">
      {{
        t('SCHEDULING.RESOURCES.PROVIDER_UPDATED', {
          count: checkedMinutesAgo,
        })
      }}
    </span>
  </section>
</template>
