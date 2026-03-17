<script setup>
import { computed, ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';

const props = defineProps({
  modelValue: {
    type: Array,
    default: () => [],
  },
  options: {
    type: Array,
    default: () => [],
  },
  placeholder: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();

const isOpen = ref(false);

const selectedOptions = computed(() =>
  props.options.filter(option => props.modelValue.includes(option.value))
);
const allOptionValues = computed(() =>
  props.options.map(option => option.value)
);
const hasSelection = computed(() => props.modelValue.length > 0);
const isAllSelected = computed(
  () =>
    props.options.length > 0 &&
    props.modelValue.length === props.options.length &&
    props.options.every(option => props.modelValue.includes(option.value))
);

const buttonLabel = computed(() => {
  if (!props.modelValue.length) {
    return props.placeholder;
  }

  if (props.modelValue.length === 1) {
    return selectedOptions.value[0]?.label || props.placeholder;
  }

  return t('SCHEDULING.GENERAL.SELECTED_COUNT', {
    count: props.modelValue.length,
  });
});
const triggerIcon = computed(() =>
  props.modelValue.length === 1
    ? selectedOptions.value[0]?.icon || 'i-lucide-filter'
    : 'i-lucide-filter'
);

const toggleOption = value => {
  if (props.modelValue.includes(value)) {
    emit(
      'update:modelValue',
      props.modelValue.filter(item => item !== value)
    );
    return;
  }

  emit('update:modelValue', [...props.modelValue, value]);
};

const selectAll = () => {
  emit('update:modelValue', allOptionValues.value);
};

const clearSelection = () => {
  emit('update:modelValue', []);
};
</script>

<template>
  <div class="relative">
    <OnClickOutside @trigger="isOpen = false">
      <div class="relative">
        <span
          class="pointer-events-none absolute inset-y-0 left-3 z-10 flex items-center text-n-slate-10"
        >
          <span class="size-4" :class="triggerIcon" aria-hidden="true" />
        </span>

        <Button
          size="sm"
          color="slate"
          variant="outline"
          justify="start"
          class="!h-8 !rounded-lg !bg-n-alpha-black2 !px-3 !py-2 !pl-9 !font-normal !outline-n-weak hover:!outline-n-slate-6"
          @click="isOpen = !isOpen"
        >
          <span
            class="min-w-0 flex-1 truncate text-left text-sm text-n-slate-12"
          >
            {{ buttonLabel }}
          </span>
          <span
            class="size-4 shrink-0 text-n-slate-10"
            :class="[isOpen ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down']"
            aria-hidden="true"
          />
        </Button>
      </div>

      <div
        v-if="isOpen"
        class="absolute right-0 z-30 mt-2 flex min-w-64 flex-col gap-3 rounded-2xl border border-n-weak bg-n-solid-2/95 p-3 shadow-xl outline outline-1 outline-n-container backdrop-blur-[16px]"
      >
        <div class="flex items-center justify-between gap-2">
          <Button
            size="sm"
            variant="ghost"
            color="slate"
            :label="t('SCHEDULING.GENERAL.SELECT_ALL')"
            :disabled="isAllSelected"
            @click="selectAll"
          />
          <Button
            size="sm"
            variant="ghost"
            color="slate"
            :label="t('SCHEDULING.GENERAL.CLEAR')"
            :disabled="!hasSelection"
            @click="clearSelection"
          />
        </div>

        <button
          v-for="option in options"
          :key="option.value"
          type="button"
          class="flex items-center gap-3 rounded-xl px-2 py-2 text-left transition-colors hover:bg-n-alpha-2"
          @click="toggleOption(option.value)"
        >
          <Checkbox
            :model-value="modelValue.includes(option.value)"
            aria-hidden="true"
            class="pointer-events-none"
            tabindex="-1"
          />
          <span
            v-if="option.icon"
            class="size-4 shrink-0 text-n-slate-11"
            :class="option.icon"
            aria-hidden="true"
          />
          <span class="min-w-0 text-sm text-n-slate-12">
            {{ option.label }}
          </span>
        </button>
      </div>
    </OnClickOutside>
  </div>
</template>
