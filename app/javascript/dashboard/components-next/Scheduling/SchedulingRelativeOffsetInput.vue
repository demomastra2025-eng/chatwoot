<script setup>
import { computed, useAttrs, watch } from 'vue';

import Input from 'dashboard/components-next/input/Input.vue';

const props = defineProps({
  autofocus: {
    type: Boolean,
    default: false,
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  label: {
    type: String,
    default: '',
  },
  max: {
    type: [String, Number],
    default: '',
  },
  min: {
    type: [String, Number],
    default: 1,
  },
  placeholder: {
    type: String,
    default: '',
  },
  size: {
    type: String,
    default: 'md',
  },
  unitAriaLabel: {
    type: String,
    default: '',
  },
  unitOptions: {
    type: Array,
    default: () => [],
  },
});

const amountValue = defineModel('amount', {
  type: [String, Number],
  default: '',
});

const unitValue = defineModel('unit', {
  type: String,
  default: 'minutes',
});

defineOptions({
  inheritAttrs: false,
});

const attrs = useAttrs();

const resolvedUnitOptions = computed(() =>
  props.unitOptions.length
    ? props.unitOptions
    : [{ label: 'minutes', value: 'minutes' }]
);

const inputClass = computed(() => [
  'tabular-nums !rounded-r-none !pr-2.5 shadow-none focus-visible:z-10',
]);

const selectClass = computed(() => {
  if (props.size === 'sm') {
    return 'w-[6.5rem]';
  }

  return 'w-[7.25rem]';
});

watch(
  resolvedUnitOptions,
  options => {
    if (options.some(option => option.value === unitValue.value)) {
      return;
    }

    unitValue.value = options[0]?.value || 'minutes';
  },
  { immediate: true }
);
</script>

<template>
  <div class="flex min-w-0 flex-col gap-1">
    <label v-if="label" class="mb-0.5 text-sm font-medium text-n-slate-12">
      {{ label }}
    </label>

    <div class="flex min-w-0 rounded-lg shadow-xs shadow-black/[.04]">
      <div class="min-w-0 flex-1">
        <Input
          v-bind="attrs"
          v-model="amountValue"
          type="number"
          inputmode="decimal"
          step="1"
          :min="String(props.min)"
          :max="props.max === '' ? '' : String(props.max)"
          :disabled="props.disabled"
          :placeholder="props.placeholder"
          :size="props.size"
          :autofocus="props.autofocus"
          :custom-input-class="inputClass"
        />
      </div>

      <div class="relative inline-flex shrink-0 self-stretch">
        <select
          v-model="unitValue"
          :aria-label="unitAriaLabel || label"
          :disabled="disabled"
          :class="selectClass"
          class="-ml-px peer h-full !mb-0 appearance-none !rounded-l-none rounded-r-lg bg-n-alpha-black2 px-2 pr-6 text-sm text-n-slate-12 outline outline-1 outline-n-weak outline-offset-[-1px] transition-all duration-500 ease-in-out hover:outline-n-slate-6 focus:z-10 focus:outline-n-brand disabled:cursor-not-allowed disabled:opacity-50 [background-image:none]"
        >
          <option
            v-for="option in resolvedUnitOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ option.label }}
          </option>
        </select>

        <span
          class="pointer-events-none absolute inset-y-0 right-2 z-10 my-auto inline-flex size-4 items-center justify-center i-lucide-chevron-down text-n-slate-10 peer-disabled:opacity-50"
          aria-hidden="true"
        />
      </div>
    </div>
  </div>
</template>
