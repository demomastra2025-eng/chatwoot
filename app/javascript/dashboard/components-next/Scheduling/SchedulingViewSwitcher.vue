<script setup>
import Button from 'dashboard/components-next/button/Button.vue';
import ButtonGroup from 'dashboard/components-next/buttonGroup/ButtonGroup.vue';

const props = defineProps({
  iconOnly: {
    type: Boolean,
    default: false,
  },
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
    class="inline-flex h-8 items-center gap-0.5 rounded-lg bg-n-alpha-black2 p-0.5 outline outline-1 outline-n-weak"
  >
    <Button
      v-for="view in views"
      :key="view.value"
      size="sm"
      color="slate"
      :variant="view.value === modelValue ? 'solid' : 'ghost'"
      :icon="iconOnly ? view.icon : ''"
      :label="iconOnly ? '' : view.label"
      :aria-label="view.label"
      :aria-pressed="view.value === modelValue"
      :title="view.label"
      type="button"
      class="!h-7 !rounded-md !text-sm"
      :class="iconOnly ? '!w-7 !p-0' : '!px-2.5'"
      @click="handleViewSelect(view.value)"
    />
  </ButtonGroup>
</template>
