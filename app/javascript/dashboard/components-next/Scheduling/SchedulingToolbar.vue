<script setup>
import { computed } from 'vue';

import Button from 'dashboard/components-next/button/Button.vue';
import DateTimePicker from 'dashboard/components/ui/DateTimePicker.vue';

import SchedulingViewSwitcher from './SchedulingViewSwitcher.vue';

const props = defineProps({
  mobile: {
    type: Boolean,
    default: false,
  },
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
    class="px-6 pb-2 pt-4"
    :class="props.transparent ? 'bg-transparent' : 'bg-n-surface-1'"
  >
    <div v-if="mobile" class="flex min-w-0 flex-col gap-2">
      <div class="flex min-w-0 items-center justify-between gap-2">
        <div class="flex min-w-0 flex-1 items-center gap-2">
          <Button
            size="sm"
            color="slate"
            variant="ghost"
            icon="i-lucide-chevron-left"
            :aria-label="$t('SCHEDULING.TOOLBAR.PREVIOUS')"
            @click="emit('previous')"
          />
          <DateTimePicker
            class="min-w-0 flex-1"
            type="date"
            :value="anchorDate"
            :display-label="currentLabel"
            hide-icon
            @change="emit('select-date', $event)"
          />
          <Button
            size="sm"
            color="slate"
            variant="ghost"
            icon="i-lucide-chevron-right"
            :aria-label="$t('SCHEDULING.TOOLBAR.NEXT')"
            @click="emit('next')"
          />
        </div>
        <div class="shrink-0"><slot name="mobile-create" /></div>
      </div>
      <div class="flex min-w-0 items-center gap-2">
        <slot name="mobile-view" />
        <div class="flex min-w-0 flex-1 items-center gap-2">
          <slot name="mobile-filters" />
        </div>
      </div>
    </div>
    <div v-else class="flex min-h-8 flex-wrap items-center gap-3">
      <div v-if="$slots.leading" class="flex shrink-0 items-center">
        <slot name="leading" />
      </div>

      <div v-if="showViewSwitcher" class="min-w-0 shrink-0">
        <SchedulingViewSwitcher
          :model-value="modelValue"
          :views="translatedViews"
          @update:model-value="emit('update:modelValue', $event)"
        />
      </div>

      <div class="flex shrink-0 flex-wrap items-center justify-start gap-2">
        <Button
          size="sm"
          color="slate"
          variant="faded"
          icon="i-lucide-chevron-left"
          :aria-label="$t('SCHEDULING.TOOLBAR.PREVIOUS')"
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
        <div class="min-w-0">
          <DateTimePicker
            type="date"
            :value="anchorDate"
            :display-label="currentLabel"
            hide-icon
            @change="emit('select-date', $event)"
          />
        </div>
        <Button
          size="sm"
          color="slate"
          variant="faded"
          icon="i-lucide-chevron-right"
          :aria-label="$t('SCHEDULING.TOOLBAR.NEXT')"
          @click="emit('next')"
        />
      </div>

      <div class="ml-auto flex min-h-8 flex-wrap items-center gap-2">
        <slot name="filters" />
        <slot name="actions" />
      </div>
    </div>
  </div>
</template>
