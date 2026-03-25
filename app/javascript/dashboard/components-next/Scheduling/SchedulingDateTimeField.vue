<script setup>
import { computed } from 'vue';
import { format } from 'date-fns';

import DateTimePicker from 'dashboard/components/ui/DateTimePicker.vue';

const props = defineProps({
  modelValue: {
    type: String,
    default: '',
  },
  type: {
    type: String,
    default: 'datetime',
    validator: value => ['date', 'time', 'datetime'].includes(value),
  },
  label: {
    type: String,
    default: '',
  },
  placeholder: {
    type: String,
    default: '',
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  message: {
    type: String,
    default: '',
  },
  messageType: {
    type: String,
    default: 'info',
    validator: value => ['info', 'error', 'success'].includes(value),
  },
  minuteStep: {
    type: Number,
    default: 5,
  },
  timePickerVariant: {
    type: String,
    default: 'wheel',
    validator: value => ['field', 'wheel'].includes(value),
  },
});

const emit = defineEmits(['update:modelValue']);

const parseModelValue = value => {
  if (!value) return null;

  if (props.type === 'date') {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
    if (!match) return null;

    const year = Number(match[1]);
    const month = Number(match[2]);
    const day = Number(match[3]);
    const date = new Date(year, month - 1, day);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  if (props.type === 'time') {
    const match = /^(\d{2}):(\d{2})$/.exec(value);
    if (!match) return null;

    const date = new Date();
    date.setHours(Number(match[1]), Number(match[2]), 0, 0);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
};

const formatModelValue = value => {
  if (!value) return '';

  if (props.type === 'date') {
    return format(value, 'yyyy-MM-dd');
  }

  if (props.type === 'time') {
    return format(value, 'HH:mm');
  }

  return format(value, "yyyy-MM-dd'T'HH:mm");
};

const pickerValue = computed(() => parseModelValue(props.modelValue));

const displayFormat = computed(() => {
  if (props.type === 'date') return 'DD.MM.YYYY';
  if (props.type === 'time') return 'HH:mm';
  return 'DD.MM.YYYY - HH:mm';
});

const messageClass = computed(() => {
  if (props.messageType === 'error') {
    return 'text-n-ruby-9 dark:text-n-ruby-9';
  }

  if (props.messageType === 'success') {
    return 'text-n-teal-10 dark:text-n-teal-10';
  }

  return 'text-n-slate-11 dark:text-n-slate-11';
});

const inputClass = computed(() => {
  return props.messageType === 'error'
    ? 'scheduling-date-time-field__input scheduling-date-time-field__input--error'
    : 'scheduling-date-time-field__input';
});

const handleChange = value => {
  emit('update:modelValue', formatModelValue(value));
};
</script>

<template>
  <div class="relative flex flex-col min-w-0 gap-1">
    <label v-if="label" class="mb-0.5 text-sm font-medium text-n-slate-12">
      {{ label }}
    </label>

    <DateTimePicker
      :value="pickerValue"
      :type="type"
      :format="displayFormat"
      :minute-step="minuteStep"
      :time-picker-variant="timePickerVariant"
      :disabled="disabled"
      :placeholder="placeholder"
      :input-class="inputClass"
      popup-class="scheduling-date-time-field__popup"
      @change="handleChange"
    />

    <p
      v-if="message"
      class="min-w-0 mt-1 mb-0 text-xs truncate transition-all duration-500 ease-in-out"
      :class="messageClass"
    >
      {{ message }}
    </p>
  </div>
</template>

<style scoped lang="scss">
:deep(.scheduling-date-time-field__input--error) {
  outline-color: rgb(var(--n-ruby-8)) !important;
}

:deep(.scheduling-date-time-field__input--error:hover),
:deep(.scheduling-date-time-field__input--error:focus),
:deep(.scheduling-date-time-field__input--error[data-state='open']) {
  outline-color: rgb(var(--n-ruby-9)) !important;
}
</style>
