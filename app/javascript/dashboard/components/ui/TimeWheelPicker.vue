<script setup>
import { Time } from '@internationalized/date';
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  defaultPlaceholder: {
    type: Object,
    default: undefined,
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  minuteStep: {
    type: Number,
    default: 5,
  },
  modelValue: {
    type: Object,
    default: undefined,
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();

const ITEM_HEIGHT = 36;
const VIEWPORT_HEIGHT = 156;
const WHEEL_SPACER = (VIEWPORT_HEIGHT - ITEM_HEIGHT) / 2;

const hourColumnRef = ref(null);
const minuteColumnRef = ref(null);
const selectedHourIndex = ref(0);
const selectedMinuteIndex = ref(0);
const lastPublishedKey = ref('');

let hourScrollTimer = null;
let minuteScrollTimer = null;

const normalizedMinuteStep = computed(() => Math.max(1, props.minuteStep || 1));
const hourOptions = Array.from({ length: 24 }, (_, index) => index);
const minuteOptions = computed(() => {
  const options = [];

  for (let value = 0; value < 60; value += normalizedMinuteStep.value) {
    options.push(value);
  }

  return options;
});

const wheelSpacerStyle = {
  height: `${WHEEL_SPACER}px`,
};

const timeKey = (hour, minute) => `${hour}:${minute}`;

const clampIndex = (index, optionsLength) => {
  return Math.min(Math.max(index, 0), Math.max(optionsLength - 1, 0));
};

const formatOptionValue = value => String(value).padStart(2, '0');

const findNearestOptionIndex = (options, value) => {
  if (!options.length) return 0;

  let nearestIndex = 0;
  let smallestGap = Number.POSITIVE_INFINITY;

  options.forEach((option, index) => {
    const gap = Math.abs(option - value);
    if (gap < smallestGap) {
      smallestGap = gap;
      nearestIndex = index;
    }
  });

  return nearestIndex;
};

const resolvedHourValue = computed(() => {
  const sourceValue = Number(
    props.modelValue?.hour ?? props.defaultPlaceholder?.hour ?? 0
  );

  return clampIndex(sourceValue, hourOptions.length);
});

const resolvedMinuteIndex = computed(() =>
  findNearestOptionIndex(
    minuteOptions.value,
    Number(props.modelValue?.minute ?? props.defaultPlaceholder?.minute ?? 0)
  )
);

const selectedMinuteValue = computed(() => {
  return minuteOptions.value[selectedMinuteIndex.value] ?? 0;
});

const hoursAriaLabel = computed(() => t('DATE_TIME_PICKER.HOURS'));
const minutesAriaLabel = computed(() => t('DATE_TIME_PICKER.MINUTES'));
const timeSeparator = ':';

const scrollColumnToIndex = (columnType, index, behavior = 'smooth') => {
  const target =
    columnType === 'hour' ? hourColumnRef.value : minuteColumnRef.value;

  if (!target) return;

  target.scrollTo({
    top: index * ITEM_HEIGHT,
    behavior,
  });
};

const publishCurrentSelection = () => {
  const hour = hourOptions[selectedHourIndex.value] ?? 0;
  const minute = selectedMinuteValue.value;
  const nextKey = timeKey(hour, minute);

  if (nextKey === lastPublishedKey.value) return;

  lastPublishedKey.value = nextKey;
  emit('update:modelValue', new Time(hour, minute));
};

const syncSelectionFromModel = () => {
  selectedHourIndex.value = resolvedHourValue.value;
  selectedMinuteIndex.value = resolvedMinuteIndex.value;
  lastPublishedKey.value = timeKey(
    resolvedHourValue.value,
    minuteOptions.value[resolvedMinuteIndex.value] ?? 0
  );

  nextTick(() => {
    scrollColumnToIndex('hour', selectedHourIndex.value, 'auto');
    scrollColumnToIndex('minute', selectedMinuteIndex.value, 'auto');
  });
};

const getColumnOptions = columnType =>
  columnType === 'hour' ? hourOptions : minuteOptions.value;

const getSelectedIndexRef = columnType =>
  columnType === 'hour' ? selectedHourIndex : selectedMinuteIndex;

const getSelectedIndexValue = columnType =>
  getSelectedIndexRef(columnType).value;

const isSelectedOption = (columnType, index) =>
  getSelectedIndexValue(columnType) === index;

const handleColumnSnap = (columnType, behavior = 'smooth') => {
  const target =
    columnType === 'hour' ? hourColumnRef.value : minuteColumnRef.value;
  const options = getColumnOptions(columnType);

  if (!target || !options.length) return;

  const nextIndex = clampIndex(
    Math.round(target.scrollTop / ITEM_HEIGHT),
    options.length
  );

  getSelectedIndexRef(columnType).value = nextIndex;
  scrollColumnToIndex(columnType, nextIndex, behavior);
  publishCurrentSelection();
};

const scheduleColumnSnap = columnType => {
  if (columnType === 'hour') {
    window.clearTimeout(hourScrollTimer);
    hourScrollTimer = window.setTimeout(() => {
      handleColumnSnap('hour');
    }, 120);
    return;
  }

  window.clearTimeout(minuteScrollTimer);
  minuteScrollTimer = window.setTimeout(() => {
    handleColumnSnap('minute');
  }, 120);
};

const handleColumnScroll = columnType => {
  if (props.disabled) return;

  const target =
    columnType === 'hour' ? hourColumnRef.value : minuteColumnRef.value;
  const options = getColumnOptions(columnType);

  if (!target || !options.length) return;

  getSelectedIndexRef(columnType).value = clampIndex(
    Math.round(target.scrollTop / ITEM_HEIGHT),
    options.length
  );

  scheduleColumnSnap(columnType);
};

const updateColumnSelection = (columnType, index, behavior = 'smooth') => {
  getSelectedIndexRef(columnType).value = index;
  scrollColumnToIndex(columnType, index, behavior);
  publishCurrentSelection();
};

const handleOptionClick = (columnType, index) => {
  if (props.disabled) return;

  updateColumnSelection(columnType, index);
};

const handleColumnKeydown = (event, columnType) => {
  if (props.disabled) return;

  const options = getColumnOptions(columnType);
  const indexRef = getSelectedIndexRef(columnType);
  let nextIndex = indexRef.value;

  if (event.key === 'ArrowUp') {
    nextIndex = clampIndex(indexRef.value - 1, options.length);
  } else if (event.key === 'ArrowDown') {
    nextIndex = clampIndex(indexRef.value + 1, options.length);
  } else if (event.key === 'Home') {
    nextIndex = 0;
  } else if (event.key === 'End') {
    nextIndex = Math.max(options.length - 1, 0);
  } else if (event.key === 'PageUp') {
    nextIndex = clampIndex(indexRef.value - 3, options.length);
  } else if (event.key === 'PageDown') {
    nextIndex = clampIndex(indexRef.value + 3, options.length);
  } else {
    return;
  }

  event.preventDefault();
  updateColumnSelection(columnType, nextIndex);
};

watch(
  [resolvedHourValue, resolvedMinuteIndex, minuteOptions],
  syncSelectionFromModel,
  { immediate: true }
);

onBeforeUnmount(() => {
  window.clearTimeout(hourScrollTimer);
  window.clearTimeout(minuteScrollTimer);
});
</script>

<template>
  <div
    class="time-wheel-picker relative overflow-hidden rounded-2xl p-5"
    :class="[disabled ? 'opacity-60' : '']"
  >
    <div
      class="pointer-events-none absolute inset-x-0 top-0 z-10 h-14 bg-gradient-to-b from-n-solid-2 via-n-solid-2/90 to-transparent"
      aria-hidden="true"
    />
    <div
      class="pointer-events-none absolute inset-x-0 bottom-0 z-10 h-14 bg-gradient-to-t from-n-solid-2 via-n-solid-2/90 to-transparent"
      aria-hidden="true"
    />
    <div
      class="pointer-events-none absolute inset-x-0 top-1/2 z-10 h-9 -translate-y-1/2 rounded-xl border border-n-container bg-n-surface-1/90 shadow-[inset_0_1px_0_rgba(255,255,255,0.12)]"
      aria-hidden="true"
    />

    <div
      class="relative z-20 grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-2"
    >
      <div class="min-w-0">
        <div class="sr-only">
          {{ hoursAriaLabel }}
        </div>
        <div
          ref="hourColumnRef"
          class="time-wheel-picker__column h-[156px] overflow-y-auto overscroll-contain rounded-xl outline-none"
          role="listbox"
          aria-orientation="vertical"
          :aria-label="hoursAriaLabel"
          :tabindex="disabled ? -1 : 0"
          @scroll="handleColumnScroll('hour')"
          @keydown="handleColumnKeydown($event, 'hour')"
        >
          <div :style="wheelSpacerStyle" aria-hidden="true" />
          <div
            v-for="(hour, index) in hourOptions"
            :key="hour"
            role="option"
            :aria-selected="isSelectedOption('hour', index)"
            :tabindex="-1"
            class="flex h-9 w-full items-center justify-center"
          >
            <button
              type="button"
              class="relative flex h-full w-full items-center justify-center rounded-xl px-2 py-1.5 text-center tabular-nums transition-all duration-150"
              :class="
                isSelectedOption('hour', index)
                  ? 'scale-100 text-[1.0625rem] font-semibold text-n-slate-12'
                  : 'scale-[0.96] text-sm font-medium text-n-slate-10'
              "
              :disabled="disabled"
              tabindex="-1"
              @click="handleOptionClick('hour', index)"
            >
              {{ formatOptionValue(hour) }}
            </button>
          </div>
          <div :style="wheelSpacerStyle" aria-hidden="true" />
        </div>
      </div>

      <div
        class="pointer-events-none flex h-9 items-center justify-center px-1 text-lg font-medium text-n-slate-10"
        aria-hidden="true"
      >
        {{ timeSeparator }}
      </div>

      <div class="min-w-0">
        <div class="sr-only">
          {{ minutesAriaLabel }}
        </div>
        <div
          ref="minuteColumnRef"
          class="time-wheel-picker__column h-[156px] overflow-y-auto overscroll-contain rounded-xl outline-none"
          role="listbox"
          aria-orientation="vertical"
          :aria-label="minutesAriaLabel"
          :tabindex="disabled ? -1 : 0"
          @scroll="handleColumnScroll('minute')"
          @keydown="handleColumnKeydown($event, 'minute')"
        >
          <div :style="wheelSpacerStyle" aria-hidden="true" />
          <div
            v-for="(minute, index) in minuteOptions"
            :key="minute"
            role="option"
            :aria-selected="isSelectedOption('minute', index)"
            :tabindex="-1"
            class="flex h-9 w-full items-center justify-center"
          >
            <button
              type="button"
              class="relative flex h-full w-full items-center justify-center rounded-xl px-2 py-1.5 text-center tabular-nums transition-all duration-150"
              :class="
                isSelectedOption('minute', index)
                  ? 'scale-100 text-[1.0625rem] font-semibold text-n-slate-12'
                  : 'scale-[0.96] text-sm font-medium text-n-slate-10'
              "
              :disabled="disabled"
              tabindex="-1"
              @click="handleOptionClick('minute', index)"
            >
              {{ formatOptionValue(minute) }}
            </button>
          </div>
          <div :style="wheelSpacerStyle" aria-hidden="true" />
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.time-wheel-picker__column {
  -ms-overflow-style: none;
  -webkit-overflow-scrolling: touch;
  scrollbar-width: none;
  touch-action: pan-y;
}

.time-wheel-picker__column::-webkit-scrollbar {
  display: none;
}
</style>
