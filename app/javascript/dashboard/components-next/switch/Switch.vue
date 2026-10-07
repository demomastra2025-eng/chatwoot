<script setup>
import { SwitchRoot, SwitchThumb } from 'reka-ui';
import { useI18n } from 'vue-i18n';

// Geometry follows the upstream Chatwoot switch: a 28x16 track and a 12px
// thumb inset 2px on every side that travels 12px, so the gaps are equal in
// both states. The thumb is absolutely positioned, so the global `button`
// padding and flex alignment cannot shift it. On is n-blue-9 (#2781F6, the
// upstream Chatwoot brand blue) in light and dark themes.

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
    class="relative inline-flex h-4 w-7 shrink-0 rounded-full p-0 bg-n-slate-6 transition-colors duration-200 ease-out outline-none focus-visible:ring-1 focus-visible:ring-n-brand focus-visible:ring-offset-2 focus-visible:ring-offset-n-slate-2 data-[state=checked]:bg-n-blue-9 disabled:cursor-not-allowed disabled:opacity-60"
    @update:model-value="updateValue"
  >
    <span class="sr-only">{{ t('SWITCH.TOGGLE') }}</span>
    <SwitchThumb
      class="absolute left-0.5 top-0.5 size-3 rounded-full bg-n-background shadow-sm transition-transform duration-200 ease-out data-[state=checked]:translate-x-3 data-[state=unchecked]:translate-x-0"
    />
  </SwitchRoot>
</template>
