<script setup>
import { computed } from 'vue';

import Button from 'dashboard/components-next/button/Button.vue';

import SchedulingViewSwitcher from './SchedulingViewSwitcher.vue';

const props = defineProps({
  currentLabel: {
    type: String,
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
});

const emit = defineEmits(['next', 'previous', 'today', 'update:modelValue']);

const translatedViews = computed(() =>
  props.views.map(view => ({
    ...view,
    label: view.label,
  }))
);
</script>

<template>
  <div
    class="flex flex-col gap-4 px-6 py-4 border-b bg-n-surface-1 border-n-weak"
  >
    <div
      class="flex flex-col gap-3 xl:flex-row xl:items-center xl:justify-between"
    >
      <div class="flex flex-wrap items-center gap-2">
        <Button
          size="sm"
          color="slate"
          variant="faded"
          icon="i-lucide-chevron-left"
          @click="emit('previous')"
        />
        <Button
          size="sm"
          color="slate"
          variant="faded"
          icon="i-lucide-chevron-right"
          @click="emit('next')"
        />
        <Button
          size="sm"
          color="slate"
          variant="outline"
          :label="$t('SCHEDULING.GENERAL.TODAY')"
          @click="emit('today')"
        />
        <span class="ml-1 text-sm font-semibold text-n-slate-12">
          {{ currentLabel }}
        </span>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <slot name="filters" />
        <SchedulingViewSwitcher
          :model-value="modelValue"
          :views="translatedViews"
          @update:model-value="emit('update:modelValue', $event)"
        />
        <slot name="actions" />
      </div>
    </div>
  </div>
</template>
