<script setup>
import { computed } from 'vue';
import BaseCheckbox from 'dashboard/components-next/checkbox/Checkbox.vue';

const props = defineProps({
  isChecked: {
    type: Boolean,
    default: false,
  },
  value: {
    type: String,
    default: null,
  },
});

const emit = defineEmits(['update']);

const checked = computed({
  get: () => props.isChecked,
  set: value => emit('update', props.value, value),
});
</script>

<template>
  <BaseCheckbox
    :id="value"
    v-model="checked"
    :value="value"
    class="mt-0.5 flex-shrink-0"
  />
</template>
