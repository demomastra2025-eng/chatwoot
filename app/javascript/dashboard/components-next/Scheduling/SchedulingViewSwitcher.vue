<script setup>
import { computed } from 'vue';

import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';

const props = defineProps({
  modelValue: {
    type: String,
    required: true,
  },
  views: {
    type: Array,
    required: true,
  },
});

const emit = defineEmits(['update:modelValue']);

const activeIndex = computed(() =>
  props.views.findIndex(view => view.value === props.modelValue)
);

const tabs = computed(() =>
  props.views.map(view => ({
    ...view,
    label: view.label,
  }))
);

const handleTabChanged = tab => {
  emit('update:modelValue', tab.value);
};
</script>

<template>
  <TabBar
    :tabs="tabs"
    :initial-active-tab="Math.max(activeIndex, 0)"
    @tab-changed="handleTabChanged"
  />
</template>
