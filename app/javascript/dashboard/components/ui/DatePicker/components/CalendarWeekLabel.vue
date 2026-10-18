<script setup>
import { computed, getCurrentInstance } from 'vue';
import { getLocalizedCalendarWeeks } from '../helpers/DatePickerHelper';

const instance = getCurrentInstance();
const localizedWeeks = computed(() =>
  getLocalizedCalendarWeeks(instance?.proxy?.$i18n?.locale)
);
</script>

<template>
  <div class="max-w-md mx-auto grid grid-cols-7 gap-2">
    <div
      v-for="day in localizedWeeks"
      :key="day.id"
      class="flex items-center justify-center font-medium text-xs text-n-slate-11 w-9 h-7 py-1.5 px-1"
    >
      {{ day.label }}
    </div>
  </div>
</template>
