<script setup>
import { computed, ref } from 'vue';
import { vOnClickOutside } from '@vueuse/components';

const props = defineProps({
  title: {
    type: String,
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
  points: {
    type: Array,
    default: () => [],
  },
  align: {
    type: String,
    default: 'right',
    validator: value => ['left', 'right'].includes(value),
  },
});

const QUESTION_MARK_ICON = '?';

const isOpen = ref(false);

const popoverClasses = computed(() =>
  props.align === 'left' ? 'left-0' : 'right-0'
);

const togglePopover = () => {
  isOpen.value = !isOpen.value;
};

const closePopover = () => {
  isOpen.value = false;
};
</script>

<template>
  <div
    v-on-click-outside="closePopover"
    class="relative inline-flex shrink-0 items-center"
  >
    <button
      type="button"
      class="inline-flex size-4 items-center justify-center rounded text-n-slate-11 transition-colors hover:text-n-slate-12 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-n-brand/20"
      :aria-expanded="isOpen"
      @click.stop="togglePopover"
    >
      <span
        aria-hidden="true"
        class="text-[10px] font-semibold leading-none text-n-slate-11"
      >
        {{ QUESTION_MARK_ICON }}
      </span>
    </button>

    <section
      v-if="isOpen"
      class="absolute top-full z-20 mt-2 w-80 rounded-xl border border-n-weak bg-n-solid-1 p-4 shadow-lg"
      :class="popoverClasses"
    >
      <div class="flex flex-col gap-3">
        <div v-if="title || description" class="flex flex-col gap-1">
          <h5 v-if="title" class="mb-0 text-sm font-medium text-n-slate-12">
            {{ title }}
          </h5>
          <p v-if="description" class="mb-0 text-sm text-n-slate-11">
            {{ description }}
          </p>
        </div>

        <ul v-if="points.length" class="mb-0 flex flex-col gap-2 ps-4 text-sm">
          <li v-for="point in points" :key="point" class="text-n-slate-11">
            {{ point }}
          </li>
        </ul>
      </div>
    </section>
  </div>
</template>
