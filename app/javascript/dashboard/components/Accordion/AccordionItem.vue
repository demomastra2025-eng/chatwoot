<script setup>
import EmojiOrIcon from 'shared/components/EmojiOrIcon.vue';

defineProps({
  title: {
    type: String,
    required: true,
  },
  compact: {
    type: Boolean,
    default: false,
  },
  secondary: {
    type: Boolean,
    default: false,
  },
  icon: {
    type: String,
    default: '',
  },
  emoji: {
    type: String,
    default: '',
  },
  isOpen: {
    type: Boolean,
    default: true,
  },
});

const emit = defineEmits(['toggle']);

const onToggle = () => {
  emit('toggle');
};
</script>

<template>
  <div class="text-sm">
    <button
      class="flex items-center select-none w-full rounded-lg outline outline-1 outline-n-weak m-0 cursor-grab justify-between drag-handle"
      :class="[
        secondary ? 'bg-n-alpha-1 py-1.5 px-3' : 'bg-n-slate-2 py-2 px-4',
        { 'rounded-bl-none rounded-br-none': isOpen },
      ]"
      @click.stop="onToggle"
    >
      <div class="flex items-center justify-between">
        <EmojiOrIcon
          v-if="icon || emoji"
          class="inline-block w-5"
          :icon="icon"
          :emoji="emoji"
        />
        <h5
          class="mb-0 py-0 pr-2 pl-0"
          :class="
            secondary
              ? 'text-xs font-medium text-n-slate-11'
              : 'text-sm text-n-slate-12'
          "
        >
          {{ title }}
        </h5>
      </div>
      <div class="flex flex-row items-center">
        <slot name="button" />
        <div class="flex justify-end w-3 text-n-blue-11 cursor-pointer">
          <fluent-icon
            v-if="isOpen"
            :size="secondary ? 18 : 24"
            icon="subtract"
            type="solid"
          />
          <fluent-icon
            v-else
            :size="secondary ? 18 : 24"
            icon="add"
            type="solid"
          />
        </div>
      </div>
    </button>
    <div
      v-if="isOpen"
      class="outline outline-1 outline-n-weak -mt-[-1px] border-t-0 rounded-br-lg rounded-bl-lg"
      :class="compact ? 'p-0' : 'px-2 py-4'"
    >
      <slot />
    </div>
  </div>
</template>
