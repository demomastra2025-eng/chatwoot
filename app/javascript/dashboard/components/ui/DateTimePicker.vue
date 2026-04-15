<script setup>
import { computed, ref, useAttrs, watch } from 'vue';
import { format as formatDate } from 'date-fns';
import { CalendarDate, Time, getLocalTimeZone } from '@internationalized/date';
import { useI18n } from 'vue-i18n';
import {
  DatePickerCalendar,
  DatePickerCell,
  DatePickerCellTrigger,
  DatePickerContent,
  DatePickerGrid,
  DatePickerGridBody,
  DatePickerGridHead,
  DatePickerGridRow,
  DatePickerHeadCell,
  DatePickerHeader,
  DatePickerNext,
  DatePickerPrev,
  DatePickerRoot,
  DatePickerTrigger,
  MonthPickerCell,
  MonthPickerCellTrigger,
  MonthPickerGrid,
  MonthPickerGridBody,
  MonthPickerGridRow,
  MonthPickerHeader,
  MonthPickerHeading,
  MonthPickerNext,
  MonthPickerPrev,
  MonthPickerRoot,
  PopoverContent,
  PopoverPortal,
  PopoverRoot,
  PopoverTrigger,
  TimeFieldInput,
  TimeFieldRoot,
  YearPickerCell,
  YearPickerCellTrigger,
  YearPickerGrid,
  YearPickerGridBody,
  YearPickerGridRow,
  YearPickerHeader,
  YearPickerHeading,
  YearPickerNext,
  YearPickerPrev,
  YearPickerRoot,
} from 'reka-ui';

import TimeWheelPicker from './TimeWheelPicker.vue';

const props = defineProps({
  confirmText: {
    type: String,
    default: '',
  },
  placeholder: {
    type: String,
    default: '',
  },
  value: {
    type: [Date, Array, String, Number],
    default: null,
  },
  type: {
    type: String,
    default: 'datetime',
    validator: value => ['date', 'time', 'datetime'].includes(value),
  },
  confirm: {
    type: Boolean,
    default: true,
  },
  clearable: {
    type: Boolean,
    default: false,
  },
  editable: {
    type: Boolean,
    default: false,
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  disabledDate: {
    type: Function,
    default: undefined,
  },
  displayLabel: {
    type: String,
    default: '',
  },
  format: {
    type: String,
    default: '',
  },
  hideIcon: {
    type: Boolean,
    default: false,
  },
  minuteStep: {
    type: Number,
    default: 5,
  },
  inputClass: {
    type: String,
    default: '',
  },
  popupClass: {
    type: String,
    default: '',
  },
  timePickerVariant: {
    type: String,
    default: 'wheel',
    validator: value => ['field', 'wheel'].includes(value),
  },
});

const emit = defineEmits(['change']);
const { locale, t } = useI18n();

defineOptions({
  inheritAttrs: false,
});

const attrs = useAttrs();

const consumeLegacyCompatibilityProps = () => [
  props.confirmText,
  props.confirm,
  props.clearable,
  props.editable,
];

consumeLegacyCompatibilityProps();

const normalizeInputDate = value => {
  if (!value) return null;

  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? null : value;
  }

  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
};

const legacyToDateFnsFormat = value =>
  value.replace(/YYYY/g, 'yyyy').replace(/YY/g, 'yy').replace(/DD/g, 'dd');

const localizeMask = (mask, localeCodeValue) => {
  if (!localeCodeValue) return mask;

  if (/^(ru|kk|uk|be|bg|sr|mk)/i.test(localeCodeValue)) {
    return mask
      .replace(/Y/g, 'Г')
      .replace(/D/g, 'Д')
      .replace(/H/g, 'Ч')
      .replace(/m/g, 'м');
  }

  return mask;
};

const areSameDates = (left, right) => {
  if (!left && !right) return true;
  if (!left || !right) return false;
  return left.getTime() === right.getTime();
};

const currentDate = ref(normalizeInputDate(props.value));
const datePickerModel = ref(undefined);
const timePickerModel = ref(undefined);
const inlineInputValue = ref('');
const inlineInputInvalid = ref(false);
const localeCode = computed(() => locale.value?.replace(/_/g, '-') || 'en');
const normalizedMinuteStep = computed(() => Math.max(1, props.minuteStep || 1));
const isInlineInputMode = computed(() => !props.displayLabel);
const calendarPlaceholder = ref(null);
const calendarPanel = ref('day');
const isDatePickerOpen = ref(false);

const resolvedMask = computed(() => {
  if (props.format) return props.format;
  if (props.type === 'date') return 'DD.MM.YYYY';
  if (props.type === 'time') return 'HH:mm';
  return 'DD.MM.YYYY - HH:mm';
});

const resolvedDisplayFormat = computed(() =>
  legacyToDateFnsFormat(resolvedMask.value)
);

const placeholderText = computed(
  () => props.placeholder || localizeMask(resolvedMask.value, localeCode.value)
);

const displayValue = computed(() => {
  if (!currentDate.value) return '';
  return formatDate(currentDate.value, resolvedDisplayFormat.value);
});

const triggerLabel = computed(() => props.displayLabel || displayValue.value);

const datePickerPlaceholder = computed(() => {
  const baseDate = currentDate.value || new Date();

  return new CalendarDate(
    baseDate.getFullYear(),
    baseDate.getMonth() + 1,
    baseDate.getDate()
  );
});

const timeDefaultPlaceholder = computed(() => {
  const baseDate = currentDate.value || new Date();
  const snappedMinutes =
    Math.floor(baseDate.getMinutes() / normalizedMinuteStep.value) *
    normalizedMinuteStep.value;

  return new Time(baseDate.getHours(), snappedMinutes);
});

const buildCalendarValue = date => {
  const baseDate = date || new Date();

  return new CalendarDate(
    baseDate.getFullYear(),
    baseDate.getMonth() + 1,
    baseDate.getDate()
  );
};

watch(
  [currentDate, () => props.type],
  ([dateValue, typeValue]) => {
    if (typeValue === 'time') return;
    calendarPlaceholder.value = buildCalendarValue(dateValue);
  },
  { immediate: true }
);

const currentCalendarPlaceholder = computed(
  () => calendarPlaceholder.value || buildCalendarValue(currentDate.value)
);

const syncModelsFromDate = nextDate => {
  currentDate.value = nextDate;

  if (props.type !== 'time') {
    datePickerModel.value = nextDate ? buildCalendarValue(nextDate) : undefined;
  }

  timePickerModel.value = nextDate
    ? new Time(nextDate.getHours(), nextDate.getMinutes())
    : undefined;

  inlineInputValue.value = nextDate
    ? formatDate(nextDate, resolvedDisplayFormat.value)
    : '';
  inlineInputInvalid.value = false;
};

watch(
  () => props.value,
  nextValue => {
    const normalizedValue = normalizeInputDate(nextValue);
    if (!areSameDates(normalizedValue, currentDate.value)) {
      syncModelsFromDate(normalizedValue);
    }
  }
);

watch(resolvedDisplayFormat, () => {
  inlineInputValue.value = currentDate.value
    ? formatDate(currentDate.value, resolvedDisplayFormat.value)
    : '';
});

const calendarMonth = computed(
  () => currentCalendarPlaceholder.value?.month || 1
);
const calendarYear = computed(
  () => currentCalendarPlaceholder.value?.year || new Date().getFullYear()
);

const monthFormatter = computed(
  () =>
    new Intl.DateTimeFormat(localeCode.value, {
      month: 'long',
      timeZone: 'UTC',
    })
);

const monthOptions = computed(() =>
  Array.from({ length: 12 }, (_, index) => ({
    label: monthFormatter.value.format(new Date(Date.UTC(2024, index, 1))),
    value: index + 1,
  }))
);

const monthLabel = computed(
  () =>
    monthOptions.value.find(option => option.value === calendarMonth.value)
      ?.label || ''
);

const textInputClasses = computed(() => [
  'reka-date-time-picker__input reset-base no-margin block min-w-0 flex-1 rounded-lg border-0 bg-n-alpha-black2 px-3 py-2.5 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] transition-all duration-150 placeholder:text-n-slate-10 disabled:cursor-not-allowed disabled:opacity-50 dark:bg-n-solid-1',
  inlineInputInvalid.value
    ? 'outline-n-ruby-8 hover:outline-n-ruby-9 focus:outline-n-ruby-9'
    : 'outline-n-weak hover:outline-n-slate-6 focus:outline-n-brand',
  props.inputClass,
]);

const inlineInputWrapperClasses = 'flex w-full items-center gap-2';

const labelTriggerClasses = computed(() => [
  'reka-date-time-picker__trigger flex w-full items-center justify-between gap-3 rounded-lg bg-n-alpha-black2 px-3 py-2 text-left outline outline-1 outline-n-weak transition-all duration-150 hover:outline-n-slate-6 focus-visible:outline-n-brand data-[state=open]:outline-n-brand disabled:cursor-not-allowed disabled:opacity-50 dark:bg-n-solid-1',
  props.inputClass,
]);

const iconTriggerClasses = computed(() => [
  'reka-date-time-picker__icon-trigger inline-flex size-4 shrink-0 items-center justify-center border-0 bg-transparent p-0 text-n-slate-10 shadow-none outline-none ring-0 transition-colors hover:text-n-slate-12 focus-visible:text-n-slate-12 focus-visible:outline-none focus-visible:ring-0 data-[state=open]:text-n-slate-12',
]);

const timePopupWidthClass = computed(() => {
  if (props.type === 'date') return 'w-[21rem]';
  if (props.type === 'datetime') {
    return props.timePickerVariant === 'wheel' ? 'w-[32rem]' : 'w-[29rem]';
  }

  return props.timePickerVariant === 'wheel' ? 'w-[18rem]' : 'w-[14rem]';
});

const popupClasses = computed(() => [
  'reka-date-time-picker__content z-[120] max-w-[calc(100vw-1rem)] overflow-x-auto rounded-xl border border-n-container bg-n-alpha-3 p-2 text-n-slate-12 shadow-md backdrop-blur-[100px] dark:bg-n-alpha-3',
  timePopupWidthClass.value,
  props.popupClass,
]);

const popupContentClasses = computed(() => {
  if (props.type !== 'datetime') {
    return 'flex flex-col';
  }

  return 'flex items-start gap-2';
});

const popupCalendarPanelClasses = computed(() => {
  return props.type === 'datetime' ? 'shrink-0' : '';
});

const popupTimePanelClasses = computed(() => [
  'shrink-0 self-start',
  props.type === 'datetime'
    ? 'border-l border-n-weak pl-2'
    : 'mt-2 border-t border-n-weak pt-2',
  props.timePickerVariant === 'wheel' ? 'w-[10rem]' : 'w-[8rem]',
]);

const segmentClass = computed(() => [
  'inline rounded px-0.5 py-0 text-[13px] text-n-slate-12 caret-transparent outline-none transition-colors focus:bg-n-alpha-2 focus:text-n-slate-12 aria-[valuetext=Empty]:text-n-slate-10 focus:aria-[valuetext=Empty]:text-n-slate-12 data-[disabled]:cursor-not-allowed data-[disabled]:opacity-50 data-[type=literal]:px-0 data-[segment=literal]:px-0 data-[segment=literal]:text-n-slate-10',
]);

const popupTimeFieldClasses =
  'inline-flex h-10 w-full items-center overflow-hidden whitespace-nowrap rounded-lg bg-n-alpha-black2 px-3 py-2 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak transition-all duration-150 focus-within:outline-n-brand data-[invalid]:outline-n-ruby-8 data-[invalid]:hover:outline-n-ruby-9 data-[invalid]:focus-within:outline-n-ruby-9 dark:bg-n-solid-1';
const useWheelTimePicker = computed(() => props.timePickerVariant === 'wheel');

const pickerNavButtonClasses =
  'flex size-9 items-center justify-center rounded-lg text-n-slate-10 transition-colors hover:bg-n-alpha-2 hover:text-n-slate-12';

const pickerModeButtonClasses =
  'inline-flex h-8 min-w-0 items-center justify-center rounded-lg px-2 text-sm font-medium text-n-slate-12 transition-colors hover:bg-n-alpha-2 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-n-brand/30';

const rootAttrs = computed(() => {
  const { class: className, ...rest } = attrs;
  return rest;
});

const maxDigitsByType = {
  date: 8,
  time: 4,
  datetime: 12,
};

const inputMaxLength = computed(() => {
  if (props.type === 'date') return 10;
  if (props.type === 'time') return 5;
  return 18;
});

const inputInputMode = computed(() =>
  props.type === 'time' ? 'numeric' : 'numeric'
);

const isDateDisabled = dateValue => {
  if (!props.disabledDate) return false;

  const jsDate = new Date(dateValue.year, dateValue.month - 1, dateValue.day);
  return props.disabledDate(jsDate);
};

const toJsDate = value => {
  if (!value || typeof value.toDate !== 'function') return null;
  return value.toDate(getLocalTimeZone());
};

const emitNextDate = nextDate => {
  syncModelsFromDate(nextDate);
  emit('change', nextDate);
};

const extractDigits = value => value.replace(/\D/g, '');

const formatDateDigits = digits => {
  const limitedDigits = digits.slice(0, maxDigitsByType.date);
  const day = limitedDigits.slice(0, 2);
  const month = limitedDigits.slice(2, 4);
  const year = limitedDigits.slice(4, 8);

  return [day, month, year].filter(Boolean).join('.');
};

const formatTimeDigits = digits => {
  const limitedDigits = digits.slice(0, maxDigitsByType.time);
  const hours = limitedDigits.slice(0, 2);
  const minutes = limitedDigits.slice(2, 4);

  return [hours, minutes].filter(Boolean).join(':');
};

const formatDateTimeDigits = digits => {
  const limitedDigits = digits.slice(0, maxDigitsByType.datetime);
  const datePart = formatDateDigits(limitedDigits.slice(0, 8));
  const timeDigits = limitedDigits.slice(8, 12);

  if (!timeDigits) return datePart;

  return `${datePart} - ${formatTimeDigits(timeDigits)}`.trim();
};

const formatMaskedInputValue = value => {
  const digits = extractDigits(value);

  if (props.type === 'date') return formatDateDigits(digits);
  if (props.type === 'time') return formatTimeDigits(digits);
  return formatDateTimeDigits(digits);
};

const countDigitsBeforeCaret = (value, caretPosition) =>
  extractDigits(value.slice(0, Math.max(0, caretPosition))).length;

const getCaretFromDigitIndex = (value, digitIndex) => {
  if (digitIndex <= 0) return 0;

  let seenDigits = 0;

  for (let index = 0; index < value.length; index += 1) {
    if (/\d/.test(value[index])) {
      seenDigits += 1;
      if (seenDigits >= digitIndex) {
        return index + 1;
      }
    }
  }

  return value.length;
};

const parseDateInputValue = value => {
  const match = /^\s*(\d{1,2})\.(\d{1,2})\.(\d{4})\s*$/.exec(value);
  if (!match) return null;

  const day = Number(match[1]);
  const month = Number(match[2]);
  const year = Number(match[3]);

  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;

  const parsedDate = new Date(year, month - 1, day);
  if (Number.isNaN(parsedDate.getTime())) return null;
  if (
    parsedDate.getFullYear() !== year ||
    parsedDate.getMonth() !== month - 1 ||
    parsedDate.getDate() !== day
  ) {
    return null;
  }

  return parsedDate;
};

const parseTimeInputValue = value => {
  const match = /^\s*(\d{1,2}):(\d{1,2})\s*$/.exec(value);
  if (!match) return null;

  const hours = Number(match[1]);
  const minutes = Number(match[2]);

  if (hours < 0 || hours > 23) return null;
  if (minutes < 0 || minutes > 59) return null;

  return { hours, minutes };
};

const parseInlineInputValue = value => {
  if (!value.trim()) return '';

  if (props.type === 'date') {
    return parseDateInputValue(value);
  }

  if (props.type === 'time') {
    const timeValue = parseTimeInputValue(value);
    if (!timeValue) return null;

    const nextDate = new Date();
    nextDate.setHours(timeValue.hours, timeValue.minutes, 0, 0);
    return nextDate;
  }

  const match = /^\s*(.+?)\s*-\s*(\d{1,2}:\d{1,2})\s*$/.exec(value);
  if (!match) return null;

  const dateValue = parseDateInputValue(match[1]);
  const timeValue = parseTimeInputValue(match[2]);
  if (!dateValue || !timeValue) return null;

  dateValue.setHours(timeValue.hours, timeValue.minutes, 0, 0);
  return dateValue;
};

const commitInlineInputValue = () => {
  const parsedValue = parseInlineInputValue(inlineInputValue.value);

  if (parsedValue === '') {
    inlineInputInvalid.value = false;
    if (currentDate.value) {
      emitNextDate(null);
    } else {
      inlineInputValue.value = '';
    }
    return;
  }

  if (!parsedValue) {
    inlineInputInvalid.value = true;
    return;
  }

  inlineInputInvalid.value = false;

  if (areSameDates(parsedValue, currentDate.value)) {
    inlineInputValue.value = formatDate(
      parsedValue,
      resolvedDisplayFormat.value
    );
    return;
  }

  emitNextDate(parsedValue);
};

const handleInlineInput = event => {
  const inputElement = event.target;
  const nextCaretDigitIndex = countDigitsBeforeCaret(
    inputElement.value,
    inputElement.selectionStart ?? inputElement.value.length
  );
  const maskedValue = formatMaskedInputValue(inputElement.value);

  inlineInputValue.value = maskedValue;
  inputElement.value = maskedValue;
  inlineInputInvalid.value = false;

  requestAnimationFrame(() => {
    const nextCaretPosition = getCaretFromDigitIndex(
      maskedValue,
      nextCaretDigitIndex
    );
    inputElement.setSelectionRange(nextCaretPosition, nextCaretPosition);
  });
};

const handleInlineBlur = () => {
  commitInlineInputValue();
};

const handleInlineEnter = () => {
  commitInlineInputValue();
};

const handleDateChange = nextValue => {
  if (!nextValue) {
    emitNextDate(null);
    return;
  }

  datePickerModel.value = nextValue.copy();
  calendarPlaceholder.value = nextValue.copy();

  if (props.type === 'datetime') {
    const timeSource = timePickerModel.value || timeDefaultPlaceholder.value;
    const nextDate = new Date(
      nextValue.year,
      nextValue.month - 1,
      nextValue.day,
      Number(timeSource?.hour ?? 0),
      Number(timeSource?.minute ?? 0),
      0,
      0
    );

    emitNextDate(nextDate);
    return;
  }

  emitNextDate(toJsDate(nextValue));
};

const handleTimeChange = nextValue => {
  if (!nextValue) {
    emitNextDate(null);
    return;
  }

  const existingDate = currentDate.value || new Date();
  const nextDate = new Date(
    existingDate.getFullYear(),
    existingDate.getMonth(),
    existingDate.getDate(),
    Number(nextValue.hour ?? 0),
    Number(nextValue.minute ?? 0),
    0,
    0
  );

  timePickerModel.value = new Time(
    Number(nextValue.hour ?? 0),
    Number(nextValue.minute ?? 0)
  );

  if (props.type === 'datetime') {
    datePickerModel.value = buildCalendarValue(nextDate);
  }

  emitNextDate(nextDate);
};

const handlePlaceholderChange = nextValue => {
  if (!nextValue) return;
  calendarPlaceholder.value = nextValue;
};

const handleDatePickerOpenChange = nextValue => {
  isDatePickerOpen.value = nextValue;
  if (!nextValue) {
    calendarPanel.value = 'day';
  }
};

const daysInMonth = (year, month) => new Date(year, month, 0).getDate();

const buildPlaceholderWithDateParts = (year, month) => {
  const source = currentCalendarPlaceholder.value;
  const day = Math.min(source?.day || 1, daysInMonth(year, month));

  return new CalendarDate(year, month, day);
};

const openMonthPanel = () => {
  calendarPanel.value = 'month';
};

const openYearPanel = () => {
  calendarPanel.value = 'year';
};

const closePickerPanel = () => {
  calendarPanel.value = 'day';
};

const handleMonthPickerChange = nextValue => {
  if (!nextValue) return;

  calendarPlaceholder.value = buildPlaceholderWithDateParts(
    nextValue.year,
    nextValue.month
  );
  calendarPanel.value = 'day';
};

const handleYearPickerChange = nextValue => {
  if (!nextValue) return;

  calendarPlaceholder.value = buildPlaceholderWithDateParts(
    nextValue.year,
    calendarMonth.value
  );
  calendarPanel.value = 'day';
};

const calendarCellClass = ({
  disabled,
  outsideView,
  selected,
  unavailable,
}) => [
  'relative flex size-9 items-center justify-center whitespace-nowrap rounded-lg border border-transparent p-0 text-sm font-normal text-n-slate-12 transition-colors focus-visible:outline-none data-focus-visible:ring-2 data-focus-visible:ring-n-brand/30 data-focus-visible:ring-offset-2',
  selected
    ? 'bg-n-brand-solid text-white hover:bg-n-brand-solid hover:text-white'
    : 'hover:bg-n-alpha-2 dark:hover:bg-n-solid-3',
  outsideView && !selected ? 'text-n-slate-9' : '',
  disabled || unavailable
    ? 'cursor-not-allowed opacity-40 hover:bg-transparent dark:hover:bg-transparent'
    : '',
];

const pickerGridCellClass = ({ disabled, selected, unavailable }) => [
  'relative flex h-10 items-center justify-center rounded-lg border border-transparent px-2 text-sm font-medium text-n-slate-12 transition-colors focus-visible:outline-none data-focus-visible:ring-2 data-focus-visible:ring-n-brand/30 data-focus-visible:ring-offset-2',
  selected
    ? 'bg-n-brand-solid text-white hover:bg-n-brand-solid hover:text-white'
    : 'hover:bg-n-alpha-2 dark:hover:bg-n-solid-3',
  disabled || unavailable
    ? 'cursor-not-allowed opacity-40 hover:bg-transparent dark:hover:bg-transparent'
    : '',
];

syncModelsFromDate(currentDate.value);
</script>

<template>
  <div
    v-bind="rootAttrs"
    class="reka-date-time-picker relative w-full"
    :class="[attrs.class]"
  >
    <DatePickerRoot
      v-if="type !== 'time'"
      :open="isDatePickerOpen"
      :model-value="datePickerModel"
      :default-placeholder="datePickerPlaceholder"
      :placeholder="currentCalendarPlaceholder"
      :close-on-select="type === 'date'"
      :disabled="disabled"
      granularity="day"
      :is-date-disabled="isDateDisabled"
      :locale="localeCode"
      :week-starts-on="1"
      @update:model-value="handleDateChange"
      @update:open="handleDatePickerOpenChange"
      @update:placeholder="handlePlaceholderChange"
    >
      <div v-if="isInlineInputMode" :class="inlineInputWrapperClasses">
        <input
          :value="inlineInputValue"
          :placeholder="placeholderText"
          :disabled="disabled"
          type="text"
          :class="textInputClasses"
          :inputmode="inputInputMode"
          :maxlength="inputMaxLength"
          autocapitalize="off"
          autocomplete="off"
          autocorrect="off"
          spellcheck="false"
          @input="handleInlineInput"
          @blur="handleInlineBlur"
          @keydown.enter.prevent="handleInlineEnter"
        />

        <DatePickerTrigger v-if="!hideIcon" as-child>
          <button
            type="button"
            :disabled="disabled"
            :class="iconTriggerClasses"
          >
            <span class="i-lucide-calendar-days size-4" aria-hidden="true" />
          </button>
        </DatePickerTrigger>
      </div>

      <DatePickerTrigger v-else as-child>
        <button type="button" :disabled="disabled" :class="labelTriggerClasses">
          <span
            class="truncate text-sm"
            :class="[currentDate ? 'text-n-slate-12' : 'text-n-slate-10']"
          >
            {{ triggerLabel || placeholderText }}
          </span>
          <span
            v-if="!hideIcon"
            class="i-lucide-calendar-days size-4 shrink-0 text-n-slate-10"
            aria-hidden="true"
          />
        </button>
      </DatePickerTrigger>

      <DatePickerContent align="start" :side-offset="8" :class="popupClasses">
        <div :class="popupContentClasses">
          <div :class="popupCalendarPanelClasses">
            <DatePickerCalendar
              v-if="calendarPanel === 'day'"
              v-slot="{ weekDays, grid }"
              class="flex flex-col gap-3"
            >
              <DatePickerHeader class="flex items-center justify-between gap-2">
                <DatePickerPrev as-child>
                  <button type="button" :class="pickerNavButtonClasses">
                    <span
                      class="i-lucide-chevron-left size-4"
                      aria-hidden="true"
                    />
                  </button>
                </DatePickerPrev>

                <div
                  class="flex min-w-0 flex-1 items-center justify-center gap-1"
                >
                  <button
                    type="button"
                    :class="pickerModeButtonClasses"
                    :aria-label="t('DATE_TIME_PICKER.MONTH')"
                    @click="openMonthPanel"
                  >
                    {{ monthLabel }}
                  </button>
                  <button
                    type="button"
                    :class="pickerModeButtonClasses"
                    :aria-label="t('DATE_TIME_PICKER.YEAR')"
                    @click="openYearPanel"
                  >
                    {{ calendarYear }}
                  </button>
                </div>

                <DatePickerNext as-child>
                  <button type="button" :class="pickerNavButtonClasses">
                    <span
                      class="i-lucide-chevron-right size-4"
                      aria-hidden="true"
                    />
                  </button>
                </DatePickerNext>
              </DatePickerHeader>

              <DatePickerGrid
                v-for="month in grid"
                :key="month.value.toString()"
                class="w-full border-separate border-spacing-1"
              >
                <DatePickerGridHead>
                  <DatePickerGridRow>
                    <DatePickerHeadCell
                      v-for="day in weekDays"
                      :key="day"
                      class="size-9 rounded-lg p-0 text-xs font-medium text-n-slate-10"
                    >
                      {{ day }}
                    </DatePickerHeadCell>
                  </DatePickerGridRow>
                </DatePickerGridHead>

                <DatePickerGridBody>
                  <DatePickerGridRow
                    v-for="(weekDates, index) in month.rows"
                    :key="`${month.value.toString()}-${index}`"
                  >
                    <DatePickerCell
                      v-for="weekDate in weekDates"
                      :key="weekDate.toString()"
                      :date="weekDate"
                      class="p-0"
                    >
                      <DatePickerCellTrigger
                        v-slot="slotProps"
                        as-child
                        :day="weekDate"
                        :month="month.value"
                      >
                        <button
                          type="button"
                          :class="calendarCellClass(slotProps)"
                          :disabled="
                            slotProps.disabled || slotProps.unavailable
                          "
                        >
                          {{ slotProps.dayValue }}
                        </button>
                      </DatePickerCellTrigger>
                    </DatePickerCell>
                  </DatePickerGridRow>
                </DatePickerGridBody>
              </DatePickerGrid>
            </DatePickerCalendar>

            <MonthPickerRoot
              v-else-if="calendarPanel === 'month'"
              :model-value="currentCalendarPlaceholder"
              :placeholder="currentCalendarPlaceholder"
              :locale="localeCode"
              @update:model-value="handleMonthPickerChange"
              @update:placeholder="handlePlaceholderChange"
            >
              <template #default="{ grid }">
                <MonthPickerHeader class="mb-3 flex items-center gap-2">
                  <button
                    type="button"
                    :class="pickerNavButtonClasses"
                    :aria-label="t('DATE_TIME_PICKER.BACK')"
                    @click="closePickerPanel"
                  >
                    <span
                      class="i-lucide-chevron-left size-4"
                      aria-hidden="true"
                    />
                  </button>

                  <MonthPickerPrev as-child>
                    <button type="button" :class="pickerNavButtonClasses">
                      <span class="i-lucide-minus size-4" aria-hidden="true" />
                    </button>
                  </MonthPickerPrev>

                  <MonthPickerHeading
                    v-slot="{ headingValue }"
                    class="flex-1 text-center text-sm font-medium text-n-slate-12"
                  >
                    {{ headingValue }}
                  </MonthPickerHeading>

                  <MonthPickerNext as-child>
                    <button type="button" :class="pickerNavButtonClasses">
                      <span class="i-lucide-plus size-4" aria-hidden="true" />
                    </button>
                  </MonthPickerNext>
                </MonthPickerHeader>

                <MonthPickerGrid
                  class="w-full border-separate border-spacing-1"
                >
                  <MonthPickerGridBody>
                    <MonthPickerGridRow
                      v-for="(months, index) in grid.rows"
                      :key="`${grid.value.toString()}-${index}`"
                    >
                      <MonthPickerCell
                        v-for="monthDate in months"
                        :key="monthDate.toString()"
                        :date="monthDate"
                        class="p-0"
                      >
                        <MonthPickerCellTrigger
                          v-slot="slotProps"
                          as-child
                          :month="monthDate"
                        >
                          <button
                            type="button"
                            :class="pickerGridCellClass(slotProps)"
                            :disabled="
                              slotProps.disabled || slotProps.unavailable
                            "
                          >
                            {{ slotProps.monthValue }}
                          </button>
                        </MonthPickerCellTrigger>
                      </MonthPickerCell>
                    </MonthPickerGridRow>
                  </MonthPickerGridBody>
                </MonthPickerGrid>
              </template>
            </MonthPickerRoot>

            <YearPickerRoot
              v-else
              :model-value="currentCalendarPlaceholder"
              :placeholder="currentCalendarPlaceholder"
              :locale="localeCode"
              @update:model-value="handleYearPickerChange"
              @update:placeholder="handlePlaceholderChange"
            >
              <template #default="{ grid }">
                <YearPickerHeader class="mb-3 flex items-center gap-2">
                  <button
                    type="button"
                    :class="pickerNavButtonClasses"
                    :aria-label="t('DATE_TIME_PICKER.BACK')"
                    @click="closePickerPanel"
                  >
                    <span
                      class="i-lucide-chevron-left size-4"
                      aria-hidden="true"
                    />
                  </button>

                  <YearPickerPrev as-child>
                    <button type="button" :class="pickerNavButtonClasses">
                      <span class="i-lucide-minus size-4" aria-hidden="true" />
                    </button>
                  </YearPickerPrev>

                  <YearPickerHeading
                    v-slot="{ headingValue }"
                    class="flex-1 text-center text-sm font-medium text-n-slate-12"
                  >
                    {{ headingValue }}
                  </YearPickerHeading>

                  <YearPickerNext as-child>
                    <button type="button" :class="pickerNavButtonClasses">
                      <span class="i-lucide-plus size-4" aria-hidden="true" />
                    </button>
                  </YearPickerNext>
                </YearPickerHeader>

                <YearPickerGrid class="w-full border-separate border-spacing-1">
                  <YearPickerGridBody>
                    <YearPickerGridRow
                      v-for="(years, index) in grid.rows"
                      :key="`${grid.value.toString()}-${index}`"
                    >
                      <YearPickerCell
                        v-for="yearDate in years"
                        :key="yearDate.toString()"
                        :date="yearDate"
                        class="p-0"
                      >
                        <YearPickerCellTrigger
                          v-slot="slotProps"
                          as-child
                          :year="yearDate"
                        >
                          <button
                            type="button"
                            :class="pickerGridCellClass(slotProps)"
                            :disabled="
                              slotProps.disabled || slotProps.unavailable
                            "
                          >
                            {{ slotProps.yearValue }}
                          </button>
                        </YearPickerCellTrigger>
                      </YearPickerCell>
                    </YearPickerGridRow>
                  </YearPickerGridBody>
                </YearPickerGrid>
              </template>
            </YearPickerRoot>
          </div>

          <div v-if="type === 'datetime'" :class="popupTimePanelClasses">
            <TimeWheelPicker
              v-if="useWheelTimePicker"
              :model-value="timePickerModel"
              :default-placeholder="timeDefaultPlaceholder"
              :disabled="disabled"
              :minute-step="normalizedMinuteStep"
              @update:model-value="handleTimeChange"
            />
            <TimeFieldRoot
              v-else
              v-slot="{ segments }"
              :model-value="timePickerModel"
              :default-placeholder="timeDefaultPlaceholder"
              :disabled="disabled"
              granularity="minute"
              :hour-cycle="24"
              hide-time-zone
              :locale="localeCode"
              :step="{ minute: normalizedMinuteStep }"
              @update:model-value="handleTimeChange"
            >
              <div :class="popupTimeFieldClasses">
                <span
                  class="i-lucide-clock-3 mr-2 size-4 shrink-0 text-n-slate-10"
                  aria-hidden="true"
                />
                <template
                  v-for="(segment, index) in segments"
                  :key="`${segment.part}-${index}`"
                >
                  <TimeFieldInput :part="segment.part" :class="segmentClass">
                    {{ segment.value }}
                  </TimeFieldInput>
                </template>
              </div>
            </TimeFieldRoot>
          </div>
        </div>
      </DatePickerContent>
    </DatePickerRoot>

    <PopoverRoot v-else>
      <div v-if="isInlineInputMode" :class="inlineInputWrapperClasses">
        <input
          :value="inlineInputValue"
          :placeholder="placeholderText"
          :disabled="disabled"
          type="text"
          :class="textInputClasses"
          :inputmode="inputInputMode"
          :maxlength="inputMaxLength"
          autocapitalize="off"
          autocomplete="off"
          autocorrect="off"
          spellcheck="false"
          @input="handleInlineInput"
          @blur="handleInlineBlur"
          @keydown.enter.prevent="handleInlineEnter"
        />

        <PopoverTrigger v-if="!hideIcon" as-child>
          <button
            type="button"
            :disabled="disabled"
            :class="iconTriggerClasses"
          >
            <span class="i-lucide-clock-3 size-4" aria-hidden="true" />
          </button>
        </PopoverTrigger>
      </div>

      <PopoverTrigger v-else as-child>
        <button type="button" :disabled="disabled" :class="labelTriggerClasses">
          <span
            class="truncate text-sm"
            :class="[currentDate ? 'text-n-slate-12' : 'text-n-slate-10']"
          >
            {{ triggerLabel || placeholderText }}
          </span>
          <span
            v-if="!hideIcon"
            class="i-lucide-clock-3 size-4 shrink-0 text-n-slate-10"
            aria-hidden="true"
          />
        </button>
      </PopoverTrigger>

      <PopoverPortal>
        <PopoverContent align="start" :side-offset="8" :class="popupClasses">
          <TimeWheelPicker
            v-if="useWheelTimePicker"
            :model-value="timePickerModel"
            :default-placeholder="timeDefaultPlaceholder"
            :disabled="disabled"
            :minute-step="normalizedMinuteStep"
            @update:model-value="handleTimeChange"
          />
          <TimeFieldRoot
            v-else
            v-slot="{ segments }"
            :model-value="timePickerModel"
            :default-placeholder="timeDefaultPlaceholder"
            :disabled="disabled"
            granularity="minute"
            :hour-cycle="24"
            hide-time-zone
            :locale="localeCode"
            :step="{ minute: normalizedMinuteStep }"
            @update:model-value="handleTimeChange"
          >
            <div :class="popupTimeFieldClasses">
              <span
                class="i-lucide-clock-3 mr-2 size-4 shrink-0 text-n-slate-10"
                aria-hidden="true"
              />
              <template
                v-for="(segment, index) in segments"
                :key="`${segment.part}-${index}`"
              >
                <TimeFieldInput :part="segment.part" :class="segmentClass">
                  {{ segment.value }}
                </TimeFieldInput>
              </template>
            </div>
          </TimeFieldRoot>
        </PopoverContent>
      </PopoverPortal>
    </PopoverRoot>
  </div>
</template>
