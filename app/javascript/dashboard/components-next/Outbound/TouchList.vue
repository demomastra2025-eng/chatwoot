<script setup>
import TouchCard from './TouchCard.vue';

defineProps({
  mutatingTouchId: {
    type: [Number, String],
    default: null,
  },
  touches: {
    type: Array,
    required: true,
  },
});

const emit = defineEmits(['analytics', 'approve', 'cancel', 'delete', 'edit']);
</script>

<template>
  <div class="flex flex-col gap-4">
    <TouchCard
      v-for="touch in touches"
      :key="touch.id"
      :touch="touch"
      :is-mutating="mutatingTouchId === touch.id"
      @edit="emit('edit', $event)"
      @analytics="emit('analytics', $event)"
      @approve="emit('approve', $event)"
      @cancel="emit('cancel', $event)"
      @delete="emit('delete', $event)"
    />
  </div>
</template>
