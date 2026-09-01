<script setup>
import { SwitchRoot, SwitchThumb } from 'reka-ui';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  disabled: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['change']);

const { t } = useI18n();

const modelValue = defineModel({
  type: Boolean,
  default: false,
});

const updateValue = value => {
  modelValue.value = value;
  emit('change', value);
};
</script>

<template>
  <SwitchRoot
    v-bind="$attrs"
    type="button"
    :model-value="modelValue"
    :disabled="props.disabled"
    class="relative inline-flex h-4 w-8 shrink-0 rounded-full border border-transparent bg-n-slate-6 transition-colors duration-200 ease-out outline-none focus-visible:ring-1 focus-visible:ring-n-brand focus-visible:ring-offset-1 focus-visible:ring-offset-n-slate-2 data-[state=checked]:bg-n-violet-9 disabled:cursor-not-allowed disabled:opacity-60"
    @update:model-value="updateValue"
  >
    <span class="sr-only">{{ t('SWITCH.TOGGLE') }}</span>
    <SwitchThumb
      class="absolute left-0.5 top-1/2 block size-3 -translate-y-1/2 rounded-full bg-white transition-transform duration-200 ease-out data-[state=checked]:translate-x-4 data-[state=unchecked]:translate-x-0"
    />
  </SwitchRoot>
</template>
