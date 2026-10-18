<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { format, subDays } from 'date-fns';
import WootDatePicker from 'dashboard/components/ui/DatePicker/DatePicker.vue';
import { DATE_RANGE_TYPES } from 'dashboard/components/ui/DatePicker/helpers/DatePickerHelper';

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

const reportPresetRanges = [
  { label: 'DATE_PICKER.DATE_RANGE_OPTIONS.TODAY', value: 'today' },
  { label: 'DATE_PICKER.DATE_RANGE_OPTIONS.YESTERDAY', value: 'yesterday' },
  {
    label: 'DATE_PICKER.DATE_RANGE_OPTIONS.LAST_7_DAYS',
    value: 'last7days',
    separator: true,
  },
  {
    label: 'DATE_PICKER.DATE_RANGE_OPTIONS.LAST_30_DAYS',
    value: 'last30days',
  },
  {
    label: 'DATE_PICKER.DATE_RANGE_OPTIONS.THIS_WEEK',
    value: 'thisWeek',
    separator: true,
  },
  {
    label: 'DATE_PICKER.DATE_RANGE_OPTIONS.MONTH_TO_DATE',
    value: 'monthToDate',
  },
  {
    label: 'DATE_PICKER.DATE_RANGE_OPTIONS.CUSTOM_RANGE',
    value: 'custom',
    separator: true,
  },
];

const parseIsoDate = value => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value || '')) return null;
  const [year, month, day] = value.split('-').map(Number);
  const date = new Date(year, month - 1, day);
  if (
    date.getFullYear() !== year ||
    date.getMonth() !== month - 1 ||
    date.getDate() !== day
  ) {
    return null;
  }
  return date;
};

const daysBetween = (fromStr, toStr) => {
  const from = Date.parse(`${fromStr}T00:00:00Z`);
  const to = Date.parse(`${toStr}T00:00:00Z`);
  if (!Number.isFinite(from) || !Number.isFinite(to)) return 0;
  return Math.round((to - from) / 86_400_000) + 1;
};

const inferRangeType = (fromStr, toStr) => {
  const days = daysBetween(fromStr, toStr);
  if (days === 7) return DATE_RANGE_TYPES.LAST_7_DAYS;
  if (days === 30) return DATE_RANGE_TYPES.LAST_30_DAYS;
  if (days === 1) {
    const todayStr = format(new Date(), 'yyyy-MM-dd');
    if (toStr === todayStr) return DATE_RANGE_TYPES.TODAY;
  }
  return DATE_RANGE_TYPES.CUSTOM_RANGE;
};

const initialStart = parseIsoDate(props.fromDate) || subDays(new Date(), 29);
const initialEnd = parseIsoDate(props.toDate) || new Date();

const pickerDateRange = ref([initialStart, initialEnd]);
const selectedRangeType = ref(
  props.fromDate && props.toDate
    ? inferRangeType(props.fromDate, props.toDate)
    : DATE_RANGE_TYPES.LAST_30_DAYS
);
const activeFromDate = ref(props.fromDate);
const activeToDate = ref(props.toDate);

watch(
  () => [props.fromDate, props.toDate],
  ([newFrom, newTo]) => {
    const parsedFrom = parseIsoDate(newFrom);
    const parsedTo = parseIsoDate(newTo);
    if (!parsedFrom || !parsedTo) return;

    const currentFrom = activeFromDate.value;
    const currentTo = activeToDate.value;
    activeFromDate.value = newFrom;
    activeToDate.value = newTo;
    pickerDateRange.value = [parsedFrom, parsedTo];

    if (newFrom !== currentFrom || newTo !== currentTo) {
      selectedRangeType.value = inferRangeType(newFrom, newTo);
    }
  },
  { immediate: true }
);

const isRangeValid = computed(() => {
  const fromStr = activeFromDate.value || props.fromDate;
  const toStr = activeToDate.value || props.toDate;
  if (!fromStr && !toStr) return true;
  if (!parseIsoDate(fromStr) || !parseIsoDate(toStr)) return false;

  const days = daysBetween(fromStr, toStr);
  return days > 0 && days <= props.maxRangeDays;
});

const onDateRangeChange = ([startDate, endDate, rangeType]) => {
  if (!startDate || !endDate) return;

  const nextFromDate = format(startDate, 'yyyy-MM-dd');
  const nextToDate = format(endDate, 'yyyy-MM-dd');
  activeFromDate.value = nextFromDate;
  activeToDate.value = nextToDate;
  pickerDateRange.value = [startDate, endDate];
  selectedRangeType.value = rangeType || DATE_RANGE_TYPES.CUSTOM_RANGE;

  emit('update:fromDate', nextFromDate);
  emit('update:toDate', nextToDate);

  const days = daysBetween(nextFromDate, nextToDate);
  if (days > 0 && days <= props.maxRangeDays && !props.isLoading) {
    emit('apply', { fromDate: nextFromDate, toDate: nextToDate });
  }
};
</script>

<template>
  <div
    class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
    data-test="report-date-range"
  >
    <div class="flex flex-wrap items-center gap-3">
      <WootDatePicker
        v-model:date-range="pickerDateRange"
        v-model:range-type="selectedRangeType"
        :preset-ranges="reportPresetRanges"
        @date-range-changed="onDateRangeChange"
      />
      <span
        v-if="timezone"
        class="inline-flex items-center gap-1.5 rounded-lg bg-n-alpha-1 px-2.5 py-1.5 text-xs text-n-slate-11"
      >
        <i
          class="i-lucide-clock-3 size-3.5 text-n-slate-10"
          aria-hidden="true"
        />
        {{ t('REPORTS.DATE_RANGE.TIMEZONE', { timezone }) }}
      </span>
    </div>
    <p
      v-if="!isRangeValid"
      class="m-0 text-xs text-n-ruby-11"
      role="alert"
    >
      {{ t('REPORTS.DATE_RANGE.MAX_DAYS', { days: maxRangeDays }) }}
    </p>
  </div>
</template>
