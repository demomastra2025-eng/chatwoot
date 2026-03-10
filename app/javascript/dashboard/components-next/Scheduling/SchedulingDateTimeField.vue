<script setup>
import { computed } from 'vue';
import { format } from 'date-fns';
import DatePicker from 'vue-datepicker-next';

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

const pickerValue = computed({
  get: () => parseModelValue(props.modelValue),
  set: value => emit('update:modelValue', formatModelValue(value)),
});

const displayFormat = computed(() => {
  if (props.type === 'date') return 'DD.MM.YYYY';
  if (props.type === 'time') return 'HH:mm';
  return 'DD.MM.YYYY HH:mm';
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
  const stateClass =
    props.messageType === 'error'
      ? 'outline-n-ruby-8 dark:outline-n-ruby-8 hover:outline-n-ruby-9 dark:hover:outline-n-ruby-9'
      : 'outline-n-weak dark:outline-n-weak hover:outline-n-slate-6 dark:hover:outline-n-slate-6 focus-within:outline-n-brand dark:focus-within:outline-n-brand';

  return [
    'scheduling-date-time-field__input',
    'block w-full h-10 reset-base text-sm !mb-0 outline outline-1 border-none border-0 outline-offset-[-1px] rounded-lg bg-n-alpha-black2 placeholder:text-n-slate-10 dark:placeholder:text-n-slate-10 disabled:cursor-not-allowed disabled:opacity-50 text-n-slate-12 transition-all duration-500 ease-in-out',
    stateClass,
  ].join(' ');
});
</script>

<template>
  <div class="relative flex flex-col min-w-0 gap-1">
    <label v-if="label" class="mb-0.5 text-sm font-medium text-n-slate-12">
      {{ label }}
    </label>

    <DatePicker
      v-model:value="pickerValue"
      :type="type"
      :format="displayFormat"
      :minute-step="minuteStep"
      :editable="false"
      :clearable="false"
      :confirm="type !== 'time'"
      :disabled="disabled"
      :placeholder="placeholder"
      :input-class="inputClass"
      popup-class="scheduling-date-time-field__popup"
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

<style scoped>
:deep(.mx-datepicker) {
  width: 100%;
}

:deep(.mx-input-wrapper) {
  width: 100%;
}

:deep(.scheduling-date-time-field__input) {
  padding: 0.625rem 0.75rem;
}

:deep(.mx-input-wrapper .mx-icon-calendar),
:deep(.mx-input-wrapper .mx-icon-clock) {
  color: rgb(var(--n-slate-10));
}

:deep(.scheduling-date-time-field__popup) {
  z-index: 120;
}
</style>
