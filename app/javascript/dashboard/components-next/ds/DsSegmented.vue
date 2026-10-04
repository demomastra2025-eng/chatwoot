<script setup>
import { ref } from 'vue';
import { useI18n } from 'vue-i18n';

// Segmented control (period switch and similar): one choice out of a few.
const props = defineProps({
  options: {
    type: Array,
    required: true,
    validator: options =>
      options.every(option => option.value !== undefined && option.label),
  },
  label: { type: String, default: '' },
});

const model = defineModel({ type: [String, Number], default: null });

const { t } = useI18n();
const buttons = ref([]);

const select = index => {
  model.value = props.options[index].value;
};

const onKeydown = (event, index) => {
  const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[
    event.key
  ];
  if (!step) return;
  event.preventDefault();
  const count = props.options.length;
  const next = (index + step + count) % count;
  select(next);
  buttons.value[next]?.focus();
};
</script>

<template>
  <div
    role="radiogroup"
    :aria-label="label || t('DESIGN_SYSTEM.SEGMENTED.LABEL')"
    class="inline-flex items-center gap-0.5 rounded-ds-control border border-solid border-n-weak bg-n-solid-2 p-0.5"
  >
    <button
      v-for="(option, index) in options"
      :key="option.value"
      :ref="el => (buttons[index] = el)"
      type="button"
      role="radio"
      :aria-checked="model === option.value"
      :tabindex="
        model === option.value || (model === null && index === 0) ? 0 : -1
      "
      class="m-0 rounded-[5px] px-[11px] py-1 text-sm leading-5 transition-colors duration-150 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-brand"
      :class="
        model === option.value
          ? 'bg-n-slate-3 text-n-slate-12'
          : 'bg-transparent text-n-slate-11 hover:text-n-slate-12'
      "
      @click="select(index)"
      @keydown="onKeydown($event, index)"
    >
      {{ option.label }}
    </button>
  </div>
</template>
