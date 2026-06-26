<script setup>
defineProps({
  compact: {
    type: Boolean,
    default: false,
  },
  layout: {
    type: String,
    default: 'col',
  },
  selectable: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['click']);

const handleClick = () => {
  emit('click');
};
</script>

<template>
  <div
    class="flex flex-col w-full outline-1 outline outline-n-container -outline-offset-1 group/cardLayout rounded-xl bg-n-solid-2"
  >
    <div
      class="flex w-full gap-3"
      :class="[
        layout === 'col' ? 'flex-col' : 'flex-row justify-between items-center',
        selectable ? 'px-10 py-6' : compact ? 'px-4 py-3' : 'px-6 py-5',
      ]"
      @click="handleClick"
    >
      <slot />
    </div>

    <slot name="after" />
  </div>
</template>
