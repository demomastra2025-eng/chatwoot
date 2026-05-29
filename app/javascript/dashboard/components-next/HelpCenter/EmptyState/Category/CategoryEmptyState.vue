<script setup>
import EmptyStateLayout from 'dashboard/components-next/EmptyStateLayout.vue';

defineProps({
  title: {
    type: String,
    default: '',
  },
  subtitle: {
    type: String,
    default: '',
  },
});
</script>

<template>
  <EmptyStateLayout
    :title="title"
    :subtitle="subtitle"
    :show-backdrop="false"
  />
</template>
