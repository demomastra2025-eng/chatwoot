<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import DatePicker from 'dashboard/components/ui/DatePicker/DatePicker.vue';
import { entityDateRanges } from 'dashboard/components/ui/DatePicker/helpers/DatePickerHelper';

const props = defineProps({
  compact: {
    type: Boolean,
    default: false,
  },
  label: {
    type: String,
    required: true,
  },
  modelValue: {
    type: Object,
    default: () => ({ from: '', to: '', type: '' }),
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();

const isActive = computed(() =>
  Boolean(props.modelValue?.from && props.modelValue?.to)
);

const dateRange = computed(() => {
  if (!isActive.value) return undefined;

  return [new Date(props.modelValue.from), new Date(props.modelValue.to)];
});

const handleDateRangeChanged = ([from, to, type]) => {
  emit('update:modelValue', {
    from: from.toISOString(),
    to: to.toISOString(),
    type,
  });
};

const clearDateRange = () => {
  emit('update:modelValue', { from: '', to: '', type: '' });
};
</script>

<template>
  <div
    class="grid min-w-0 gap-2 md:col-span-2"
    :class="{
      'md:grid-cols-[7.5rem_minmax(0,1fr)] md:items-center md:gap-3': compact,
    }"
  >
    <span class="text-sm font-medium text-n-slate-12">{{ label }}</span>
    <div class="flex min-w-0 flex-wrap items-center gap-2">
      <DatePicker
        :active="isActive"
        compact
        compact-scale="medium"
        compact-trigger
        :date-range="dateRange"
        :inactive-label="t('DATE_PICKER.DATE_RANGE_OPTIONS.ALL_TIME')"
        popover-align="center"
        :preset-ranges="entityDateRanges"
        :range-type="modelValue.type || undefined"
        single-calendar
        @date-range-changed="handleDateRangeChanged"
      />
      <Button
        v-if="isActive"
        type="button"
        size="sm"
        color="slate"
        variant="ghost"
        icon="i-lucide-x"
        :label="t('CRM.FILTERS.CLEAR_DATE_RANGE')"
        @click="clearDateRange"
      />
    </div>
  </div>
</template>
