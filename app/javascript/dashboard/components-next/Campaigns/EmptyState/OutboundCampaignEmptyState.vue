<script setup>
import EmptyStateLayout from 'dashboard/components-next/EmptyStateLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';

defineProps({
  title: {
    type: String,
    default: '',
  },
  subtitle: {
    type: String,
    default: '',
  },
  buttonLabel: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['click']);
</script>

<template>
  <EmptyStateLayout :title="title" :subtitle="subtitle" :show-backdrop="false">
    <template #actions>
      <slot name="actions">
        <Button
          v-if="buttonLabel"
          :label="buttonLabel"
          icon="i-lucide-plus"
          size="sm"
          @click="emit('click')"
        />
      </slot>
    </template>
  </EmptyStateLayout>
</template>
