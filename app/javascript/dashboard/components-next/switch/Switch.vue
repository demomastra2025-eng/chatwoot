<script setup>
import { SwitchRoot, SwitchThumb } from 'reka-ui';
import { useI18n } from 'vue-i18n';

// One switch for the whole app (owner 11.10: a little larger than upstream
// Chatwoot). A 36x20 track and a 16px thumb inset 2px on every side that
// travels 16px, so the gaps are equal in both states. The thumb is absolutely
// positioned, so the global `button` padding and flex alignment cannot shift
// it. On is the brand colour of primary buttons (brand-solid) in light; in
// dark brand-solid is too dark against the page, so the lighter violet-10 is
// used there. The thumb stays light in both themes and carries a shadow so it
// reads on both track colours. Never resize the switch from a page.

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
    class="relative inline-flex h-5 w-9 shrink-0 rounded-full p-0 bg-n-slate-6 transition-colors duration-200 ease-out outline-none focus-visible:ring-1 focus-visible:ring-n-brand focus-visible:ring-offset-2 focus-visible:ring-offset-n-slate-2 data-[state=checked]:bg-n-brand-solid dark:data-[state=checked]:bg-n-violet-10 disabled:cursor-not-allowed disabled:opacity-50"
    @update:model-value="updateValue"
  >
    <span class="sr-only">{{ t('SWITCH.TOGGLE') }}</span>
    <SwitchThumb
      class="pointer-events-none absolute left-0.5 top-0.5 size-4 rounded-full bg-n-background shadow-md transition-transform duration-200 ease-out dark:bg-n-slate-12 data-[state=checked]:translate-x-4 data-[state=unchecked]:translate-x-0"
    />
  </SwitchRoot>
</template>
