<script setup>
import { computed } from 'vue';

const props = defineProps({
  value: { type: [Number, String], default: 0 },
});

const count = computed(() => Number(props.value) || 0);
const label = computed(() => (count.value > 99 ? '99+' : String(count.value)));
</script>

<template>
  <span class="contents">
    <span
      v-if="count > 0"
      data-test-id="sidebar-unread-badge"
      class="shrink-0 rounded-md bg-n-brand/10 px-1.5 text-xs font-medium leading-5 text-n-brand"
    >
      {{ label }}
    </span>
  </span>
</template>
