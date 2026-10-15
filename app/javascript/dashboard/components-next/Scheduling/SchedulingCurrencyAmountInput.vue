<script setup>
import { computed, useAttrs } from 'vue';

import Input from 'dashboard/components-next/input/Input.vue';

const props = defineProps({
  autofocus: {
    type: Boolean,
    default: false,
  },
  currencies: {
    type: Array,
    default: () => ['KZT'],
  },
  currencyAriaLabel: {
    type: String,
    default: '',
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
    default: 0,
  },
  placeholder: {
    type: String,
    default: '',
  },
  size: {
    type: String,
    default: 'md',
  },
  step: {
    type: [String, Number],
    default: '0.01',
  },
  symbols: {
    type: Object,
    default: () => ({
      EUR: 'EUR',
      KZT: '₸',
      RUB: '₽',
      USD: '$',
    }),
  },
});

const amountValue = defineModel('amount', {
  type: [String, Number],
  default: '',
});

const currencyValue = defineModel('currency', {
  type: String,
  default: 'KZT',
});

defineOptions({
  inheritAttrs: false,
});

const attrs = useAttrs();

const resolvedCurrencies = computed(() =>
  props.currencies.length ? props.currencies : ['KZT']
);

const resolvedCurrency = computed(() => {
  if (resolvedCurrencies.value.includes(currencyValue.value)) {
    return currencyValue.value;
  }

  return resolvedCurrencies.value[0];
});

const currencySymbol = computed(
  () => props.symbols[resolvedCurrency.value] || resolvedCurrency.value
);

const inputClass = computed(() => [
  'tabular-nums !rounded-r-none !pl-8 !pr-2.5 shadow-none focus-visible:z-10',
]);

const selectClass = computed(() => {
  if (props.size === 'sm') {
    return 'w-[4.25rem]';
  }

  return 'w-[4.5rem]';
});
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
          :step="props.step"
          :min="String(props.min)"
          :max="props.max === '' ? '' : String(props.max)"
          :disabled="props.disabled"
          :placeholder="props.placeholder"
          :size="props.size"
          :autofocus="props.autofocus"
          :custom-input-class="inputClass"
        >
          <template #prefix>
            <span
              class="pointer-events-none absolute inset-y-0 left-2.5 flex items-center justify-center text-sm text-n-slate-10"
            >
              {{ currencySymbol }}
            </span>
          </template>
        </Input>
      </div>

      <div class="relative inline-flex shrink-0 self-stretch">
        <select
          v-model="currencyValue"
          :aria-label="currencyAriaLabel || label"
          :disabled="disabled"
          :class="selectClass"
          class="-ml-px peer h-full !mb-0 appearance-none !rounded-l-none rounded-r-lg bg-n-alpha-black2 px-2 pr-6 text-sm text-n-slate-12 outline outline-1 outline-n-weak outline-offset-[-1px] transition-all duration-500 ease-in-out hover:outline-n-slate-6 focus:z-10 focus:outline-n-brand disabled:cursor-not-allowed disabled:opacity-50 [background-image:none]"
        >
          <option
            v-for="currency in resolvedCurrencies"
            :key="currency"
            :value="currency"
          >
            {{ currency }}
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
