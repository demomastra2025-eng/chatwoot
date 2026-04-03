<script setup>
import { computed } from 'vue';
const props = defineProps({
  title: {
    type: String,
    required: true,
  },
  consumed: {
    type: Number,
    required: true,
  },
  totalCount: {
    type: Number,
    required: true,
  },
  displayConsumed: {
    type: String,
    default: '',
  },
  displayTotal: {
    type: String,
    default: '',
  },
  unlimited: {
    type: Boolean,
    default: false,
  },
});

const percent = computed(() => {
  if (props.unlimited) {
    return 0;
  }

  if (props.totalCount <= 0) {
    return props.consumed > 0 ? 100 : 0;
  }

  return Math.min(100, Math.round((props.consumed / props.totalCount) * 100));
});

const colorClass = computed(() => {
  if (percent.value < 50) {
    return 'bg-n-teal-10';
  }
  if (percent.value < 80) {
    return 'bg-n-amber-10';
  }
  return 'bg-n-ruby-10';
});

const separator = ' / ';
</script>

<template>
  <div
    class="flex gap-5 items-center justify-between text-xs uppercase text-n-slate-10"
  >
    <div class="font-medium tracking-wider">
      {{ title }}
    </div>
    <div class="tabular-nums">
      {{ displayConsumed || consumed }}{{ separator
      }}{{ displayTotal || totalCount }}
    </div>
  </div>
  <div
    v-if="!unlimited"
    class="rounded-full overflow-hidden h-2 w-full bg-n-slate-4 mt-2"
  >
    <div class="h-2" :class="colorClass" :style="{ width: `${percent}%` }" />
  </div>
</template>
