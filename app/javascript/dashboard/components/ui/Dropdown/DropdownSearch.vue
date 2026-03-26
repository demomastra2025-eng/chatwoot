<script setup>
import { defineEmits, defineModel } from 'vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

defineProps({
  inputPlaceholder: {
    type: String,
    default: '',
  },
  showClearFilter: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['remove']);

const value = defineModel({
  type: String,
  default: '',
});
</script>

<template>
  <div
    class="flex items-center justify-between h-10 min-h-[40px] sticky top-0 bg-n-solid-2 dark:bg-n-solid-2 z-10 gap-2 px-3 border-b rounded-t-xl border-n-weak"
  >
    <div class="relative flex items-center w-full" @keyup.space.prevent>
      <input
        v-model="value"
        :placeholder="inputPlaceholder"
        type="search"
        class="w-full mb-0 bg-transparent text-sm text-n-slate-12 placeholder:text-n-slate-10 reset-base !outline-0 !outline-none [appearance:textfield] [&::-webkit-search-cancel-button]:appearance-none [&::-webkit-search-decoration]:appearance-none [&::-webkit-search-results-button]:appearance-none [&::-webkit-search-results-decoration]:appearance-none ltr:pl-3 rtl:pr-3 ltr:pr-8 rtl:pl-8"
      />
      <fluent-icon
        icon="search"
        size="16"
        class="absolute top-1/2 -translate-y-1/2 text-n-slate-11 pointer-events-none ltr:right-0 rtl:left-0"
      />
    </div>
    <!-- Clear filter button -->
    <NextButton
      v-if="!modelValue && showClearFilter"
      faded
      xs
      class="flex-shrink-0"
      :label="$t('REPORT.FILTER_ACTIONS.CLEAR_FILTER')"
      @click="emit('remove')"
    />
  </div>
</template>
