<script setup>
import { computed, getCurrentInstance } from 'vue';
import {
  dateRanges,
  resolveDatePickerLocale,
} from '../helpers/DatePickerHelper';
import { format, isSameYear, isValid } from 'date-fns';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  active: {
    type: Boolean,
    default: true,
  },
  inactiveLabel: {
    type: String,
    default: '',
  },
  ranges: {
    type: Array,
    default: () => dateRanges,
  },
  selectedStartDate: Date,
  selectedEndDate: Date,
  selectedRange: {
    type: String,
    default: '',
  },
  showMonthNavigation: {
    type: Boolean,
    default: false,
  },
  canNavigateNext: {
    type: Boolean,
    default: false,
  },
  compact: {
    type: Boolean,
    default: false,
  },
  navigationLabel: {
    type: String,
    default: null,
  },
});

const emit = defineEmits(['open', 'navigateMonth']);
const instance = getCurrentInstance();

const activeLocale = computed(() =>
  resolveDatePickerLocale(instance?.proxy?.$i18n?.locale)
);

const formatDateRange = computed(() => {
  const startDate = props.selectedStartDate;
  const endDate = props.selectedEndDate;

  if (!isValid(startDate) || !isValid(endDate)) {
    return '';
  }

  const locale = activeLocale.value;
  const crossesYears = !isSameYear(startDate, endDate);
  const fullFormatter = new Intl.DateTimeFormat(locale, {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  });

  if (crossesYears) {
    return `${fullFormatter.format(startDate)} - ${fullFormatter.format(endDate)}`;
  }

  const shortFormatter = new Intl.DateTimeFormat(locale, {
    month: 'short',
    day: 'numeric',
  });
  return `${shortFormatter.format(startDate)} - ${fullFormatter.format(endDate)}`;
});

const compactDateRange = computed(() => {
  const startDate = props.selectedStartDate;
  const endDate = props.selectedEndDate;

  if (!isValid(startDate) || !isValid(endDate)) return '';

  if (isSameYear(startDate, endDate)) {
    return `${format(startDate, 'dd.MM')} – ${format(endDate, 'dd.MM')}`;
  }

  return `${format(startDate, 'dd.MM.yy')}–${format(endDate, 'dd.MM.yy')}`;
});

const activeDateRange = computed(
  () =>
    props.ranges?.find(range => range.value === props.selectedRange)?.label ||
    ''
);

const openDatePicker = () => {
  emit('open');
};
</script>

<template>
  <div class="inline-flex max-w-full min-w-0 items-center gap-1">
    <button
      type="button"
      class="relative inline-flex h-8 items-center gap-2 rounded-lg bg-n-alpha-2 px-3 py-1.5 hover:bg-n-alpha-1 active:bg-n-alpha-1"
      :class="props.compact ? 'min-w-0 max-w-full' : 'flex-shrink-0'"
      @click="openDatePicker"
    >
      <Icon
        icon="i-lucide-calendar-range"
        class="text-n-slate-11 size-3.5 flex-shrink-0"
      />
      <span class="text-sm font-medium text-n-slate-12 truncate">
        {{
          active
            ? props.compact && selectedRange === 'custom'
              ? compactDateRange
              : navigationLabel || $t(activeDateRange)
            : inactiveLabel || $t('DATE_PICKER.DATE_RANGE_OPTIONS.ALL_TIME')
        }}
      </span>
      <span
        v-if="active && !props.compact"
        class="truncate text-sm font-medium text-n-slate-11"
      >
        {{ formatDateRange }}
      </span>
      <Icon
        icon="i-lucide-chevron-down"
        class="text-n-slate-12 size-4 flex-shrink-0"
      />
    </button>
    <NextButton
      v-if="showMonthNavigation"
      v-tooltip.top="$t('DATE_PICKER.PREVIOUS_PERIOD')"
      slate
      faded
      sm
      icon="i-lucide-chevron-left"
      class="rtl:rotate-180"
      @click="emit('navigateMonth', 'prev')"
    />
    <NextButton
      v-if="showMonthNavigation"
      v-tooltip.top="$t('DATE_PICKER.NEXT_PERIOD')"
      slate
      faded
      sm
      icon="i-lucide-chevron-right"
      class="rtl:rotate-180"
      :disabled="!canNavigateNext"
      @click="emit('navigateMonth', 'next')"
    />
  </div>
</template>
