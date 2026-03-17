<script setup>
import Radio from 'dashboard/components-next/radio/Radio.vue';

defineProps({
  active: {
    type: Boolean,
    default: false,
  },
  title: {
    type: String,
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
  lightImage: {
    type: String,
    default: '',
  },
  darkImage: {
    type: String,
    default: '',
  },
});
</script>

<template>
  <button
    class="flex flex-col gap-4 w-full h-fit p-4 rounded-md border border-n-weak dark:border-n-weak"
    :class="{
      'border-n-brand ': active,
    }"
  >
    <div class="flex flex-col gap-2 items-center w-full rounded-t-[5px]">
      <div class="grid grid-cols-[1fr_auto] items-center w-full gap-1">
        <div
          class="overflow-hidden text-base font-medium text-n-slate-12 text-left"
        >
          <span class="block truncate">{{ title }}</span>
        </div>
        <Radio
          :model-value="active ? title : null"
          :name="`hotkey-${title}`"
          :value="title"
          aria-hidden="true"
          class="pointer-events-none"
          tabindex="-1"
        />
      </div>
      <span
        class="text-n-slate-12 text-sm line-clamp-2 leading-[1.4] text-start"
      >
        {{ description }}
      </span>
    </div>

    <div>
      <img
        :src="lightImage"
        :alt="`Light themed image for ${title}`"
        class="block object-cover w-full dark:hidden"
      />
      <img
        :src="darkImage"
        :alt="`Dark themed image for ${title}`"
        class="hidden object-cover w-full dark:block"
      />
    </div>
  </button>
</template>
