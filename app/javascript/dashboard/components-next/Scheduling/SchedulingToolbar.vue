<script setup>
import { computed } from 'vue';

import Button from 'dashboard/components-next/button/Button.vue';
import DateTimePicker from 'dashboard/components/ui/DateTimePicker.vue';

import SchedulingViewSwitcher from './SchedulingViewSwitcher.vue';

const props = defineProps({
  currentLabel: {
    type: String,
    required: true,
  },
  anchorDate: {
    type: [String, Date],
    required: true,
  },
  modelValue: {
    type: String,
    required: true,
  },
  views: {
    type: Array,
    required: true,
  },
  transparent: {
    type: Boolean,
    default: false,
  },
  showToday: {
    type: Boolean,
    default: true,
  },
  showViewSwitcher: {
    type: Boolean,
    default: true,
  },
});

const emit = defineEmits([
  'next',
  'previous',
  'select-date',
  'today',
  'update:modelValue',
]);

const translatedViews = computed(() =>
  props.views.map(view => ({
    ...view,
    label: view.label,
  }))
);
</script>

<template>
  <div
    class="px-5 pb-2 pt-4"
    :class="props.transparent ? 'bg-transparent' : 'bg-n-surface-1'"
  >
    <div class="flex flex-wrap items-center gap-3">
      <div v-if="$slots.leading" class="flex items-center">
        <slot name="leading" />
      </div>

      <div v-if="showViewSwitcher" class="min-w-0">
        <SchedulingViewSwitcher
          :model-value="modelValue"
          :views="translatedViews"
          @update:model-value="emit('update:modelValue', $event)"
        />
      </div>

      <div class="flex flex-wrap items-center justify-start gap-2">
        <Button
          size="sm"
          color="slate"
          variant="faded"
          icon="i-lucide-chevron-left"
          @click="emit('previous')"
        />
        <Button
          v-if="showToday"
          size="sm"
          color="slate"
          variant="outline"
          :label="$t('SCHEDULING.GENERAL.TODAY')"
          @click="emit('today')"
        />
        <DateTimePicker
          class="!w-auto"
          type="date"
          :value="anchorDate"
          :display-label="currentLabel"
          hide-icon
          input-class="!h-8 !w-auto !bg-n-alpha-black2 !px-3 !py-1.5 !text-sm !font-semibold !text-n-slate-12 !outline-n-weak hover:!outline-n-slate-6 focus-visible:!outline-n-brand data-[state=open]:!outline-n-brand"
          @change="emit('select-date', $event)"
        />
        <Button
          size="sm"
          color="slate"
          variant="faded"
          icon="i-lucide-chevron-right"
          @click="emit('next')"
        />
      </div>

      <div class="ml-auto flex flex-wrap items-center gap-2">
        <slot name="filters" />
        <slot name="actions" />
      </div>
    </div>
  </div>
</template>
