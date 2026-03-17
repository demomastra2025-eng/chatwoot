<script setup>
import Button from 'dashboard/components-next/button/Button.vue';
import ButtonGroup from 'dashboard/components-next/buttonGroup/ButtonGroup.vue';

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

const handleViewSelect = value => {
  if (value === props.modelValue) return;
  emit('update:modelValue', value);
};
</script>

<template>
  <ButtonGroup
    class="inline-flex items-center gap-1 rounded-xl bg-n-alpha-black2 p-0.5 outline outline-1 outline-n-weak"
  >
    <Button
      v-for="view in views"
      :key="view.value"
      size="sm"
      color="slate"
      :variant="view.value === modelValue ? 'solid' : 'ghost'"
      :label="view.label"
      class="!h-8 !rounded-lg !px-3 !text-sm"
      @click="handleViewSelect(view.value)"
    />
  </ButtonGroup>
</template>
