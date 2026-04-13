<script setup>
import TouchPlanCard from './TouchPlanCard.vue';

defineProps({
  hasEntityContext: {
    type: Boolean,
    default: false,
  },
  mutatingPlanId: {
    type: [Number, String],
    default: null,
  },
  touchPlans: {
    type: Array,
    required: true,
  },
});

const emit = defineEmits(['apply', 'archive', 'edit']);
</script>

<template>
  <div class="flex flex-col gap-4">
    <TouchPlanCard
      v-for="touchPlan in touchPlans"
      :key="touchPlan.id"
      :touch-plan="touchPlan"
      :has-entity-context="hasEntityContext"
      :is-mutating="mutatingPlanId === touchPlan.id"
      @edit="emit('edit', $event)"
      @apply="emit('apply', $event)"
      @archive="emit('archive', $event)"
    />
  </div>
</template>
