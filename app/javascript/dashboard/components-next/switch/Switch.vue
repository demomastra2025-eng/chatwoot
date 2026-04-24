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
    :model-value="modelValue"
    :disabled="props.disabled"
    class="inline-flex h-[16px] w-8 shrink-0 items-center rounded-full border border-transparent bg-n-slate-6 p-0.5 shadow-sm transition-colors duration-200 ease-out outline-none focus-visible:ring-1 focus-visible:ring-n-brand focus-visible:ring-offset-2 focus-visible:ring-offset-n-slate-2 data-[state=checked]:bg-n-brand-solid disabled:cursor-not-allowed disabled:opacity-60"
    @update:model-value="updateValue"
  >
    <span class="sr-only">{{ t('SWITCH.TOGGLE') }}</span>
    <SwitchThumb
      class="block size-[12px] rounded-full bg-n-background shadow-sm transition-transform duration-200 ease-out data-[state=checked]:translate-x-[16px] data-[state=unchecked]:translate-x-0"
    />
  </SwitchRoot>
</template>
