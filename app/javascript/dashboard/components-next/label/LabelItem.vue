<script setup>
import { computed } from 'vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  isSystemMetaAdsLabel,
  labelDisplayTitle,
  labelMarkerColor,
  labelMarkerEmoji,
  labelMarkerType,
} from 'dashboard/helper/labels';

const props = defineProps({
  label: {
    type: Object,
    default: null,
  },
  isHovered: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['remove', 'hover']);

const isMetaAdsSystem = computed(() => isSystemMetaAdsLabel(props.label));

const handleRemoveLabel = () => {
  emit('remove', props.label);
};

const handleMouseEnter = () => {
  // Notify parent component when this label is hovered
  // Added this to show the remove button with transition when hovering over the label
  // This will solve the flickering issue when hovering over the last label item
  emit('hover', props.label?.id);
};
</script>

<template>
  <div
    class="flex items-center overflow-hidden transition-all duration-300 ease-out h-7"
    :class="
      isMetaAdsSystem
        ? 'rounded-full border border-n-blue-4 bg-n-blue-3 px-2.5 py-1 text-n-blue-11 dark:border-n-blue-6 dark:bg-n-blue-4/30'
        : 'rounded-md bg-n-alpha-2 px-1 py-1'
    "
    @mouseenter="handleMouseEnter"
  >
    <span
      v-if="isMetaAdsSystem"
      class="i-lucide-megaphone size-3.5 shrink-0 ltr:mr-1.5 rtl:ml-1.5 text-n-blue-11"
      aria-hidden="true"
    />
    <div
      v-else-if="labelMarkerType(label) === 'color'"
      class="size-2 m-0.5 rounded-sm"
      :style="{ backgroundColor: labelMarkerColor(label) }"
    />
    <span
      v-else
      class="inline-flex items-center justify-center size-3 overflow-hidden text-xs leading-none"
    >
      {{ labelMarkerEmoji(label) }}
    </span>
    <span
      class="text-sm ltr:mr-px rtl:ml-px"
      :class="
        isMetaAdsSystem ? 'font-medium text-n-blue-11' : 'text-n-slate-12'
      "
    >
      {{ labelDisplayTitle(label) }}
    </span>
    <div
      class="w-0 flex relative flex-shrink-0 overflow-hidden transition-[width] duration-300 ease-out"
      :class="[
        isMetaAdsSystem
          ? 'ltr:left-2.5 rtl:right-2.5'
          : 'ltr:left-1 rtl:right-1',
        { 'w-6': isHovered },
      ]"
    >
      <Button
        class="transition-opacity duration-200 !h-7 ltr:rounded-l-none rtl:rounded-r-none w-6 bg-transparent"
        :class="[
          isMetaAdsSystem
            ? '!text-n-blue-11 hover:!bg-n-blue-4/50 ltr:rounded-r-full rtl:rounded-l-full'
            : 'ltr:rounded-r-md rtl:rounded-l-md',
          { 'opacity-0': !isHovered, 'opacity-100': isHovered },
        ]"
        type="button"
        slate
        xs
        faded
        icon="i-lucide-x"
        @click="handleRemoveLabel"
      />
    </div>
  </div>
</template>
