<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  fromDate: {
    type: String,
    default: '',
  },
  toDate: {
    type: String,
    default: '',
  },
  timezone: {
    type: String,
    default: 'UTC',
  },
  maxRangeDays: {
    type: Number,
    default: 90,
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['update:fromDate', 'update:toDate', 'apply']);
const { t } = useI18n();

const isRangeValid = computed(() => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(props.fromDate)) return false;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(props.toDate)) return false;

  const from = Date.parse(`${props.fromDate}T00:00:00Z`);
  const to = Date.parse(`${props.toDate}T00:00:00Z`);
  if (
    !Number.isFinite(from) ||
    !Number.isFinite(to) ||
    new Date(from).toISOString().slice(0, 10) !== props.fromDate ||
    new Date(to).toISOString().slice(0, 10) !== props.toDate
  ) {
    return false;
  }

  const days = Math.round((to - from) / 86_400_000) + 1;

  return days > 0 && days <= props.maxRangeDays;
});

const apply = () => {
  if (!isRangeValid.value || props.isLoading) return;

  emit('apply', { fromDate: props.fromDate, toDate: props.toDate });
};
</script>

<template>
  <form
    class="flex flex-col gap-3 rounded-xl border border-n-weak bg-n-surface-1 p-3 sm:flex-row sm:items-end sm:justify-between"
    data-test="report-date-range"
    @submit.prevent="apply"
  >
    <div class="grid grid-cols-2 gap-3">
      <label
        class="flex min-w-0 flex-col gap-1 text-xs font-medium text-n-slate-11"
      >
        <span>{{ t('REPORTS.DATE_RANGE.FROM') }}</span>
        <input
          :value="fromDate"
          class="h-8 min-w-0 rounded-md border border-n-weak bg-n-surface-1 px-2 text-sm text-n-slate-12 outline-none focus:border-n-brand"
          data-test="report-from-date"
          type="date"
          @input="emit('update:fromDate', $event.target.value)"
        />
      </label>
      <label
        class="flex min-w-0 flex-col gap-1 text-xs font-medium text-n-slate-11"
      >
        <span>{{ t('REPORTS.DATE_RANGE.TO') }}</span>
        <input
          :value="toDate"
          class="h-8 min-w-0 rounded-md border border-n-weak bg-n-surface-1 px-2 text-sm text-n-slate-12 outline-none focus:border-n-brand"
          data-test="report-to-date"
          type="date"
          @input="emit('update:toDate', $event.target.value)"
        />
      </label>
    </div>
    <div class="flex items-end justify-between gap-3 sm:justify-end">
      <span class="text-xs text-n-slate-10">
        {{ t('REPORTS.DATE_RANGE.TIMEZONE', { timezone }) }}
      </span>
      <Button
        size="sm"
        :label="t('REPORTS.DATE_RANGE.APPLY')"
        :disabled="!isRangeValid || isLoading"
        :is-loading="isLoading"
        data-test="apply-report-range"
        type="submit"
      />
    </div>
    <p
      v-if="fromDate && toDate && !isRangeValid"
      class="m-0 text-xs text-n-ruby-11 sm:basis-full"
      role="alert"
    >
      {{ t('REPORTS.DATE_RANGE.MAX_DAYS', { days: maxRangeDays }) }}
    </p>
  </form>
</template>
