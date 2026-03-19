<script setup>
import { ref, computed, watch, nextTick, useSlots } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBoxDropdown from 'dashboard/components-next/combobox/ComboBoxDropdown.vue';

const props = defineProps({
  options: {
    type: Array,
    required: true,
    validator: value =>
      value.every(option => 'value' in option && 'label' in option),
  },
  placeholder: { type: String, default: '' },
  modelValue: { type: [String, Number], default: '' },
  disabled: { type: Boolean, default: false },
  searchPlaceholder: { type: String, default: '' },
  emptyState: { type: String, default: '' },
  message: { type: String, default: '' },
  hasError: { type: Boolean, default: false },
  useApiResults: { type: Boolean, default: false }, // useApiResults prop to determine if search is handled by API
  inputLike: { type: Boolean, default: false },
});

const emit = defineEmits(['update:modelValue', 'search']);

const { t } = useI18n();
const slots = useSlots();

const selectedValue = ref(props.modelValue);
const open = ref(false);
const search = ref('');
const dropdownRef = ref(null);
const comboboxRef = ref(null);
const dropdownStyle = ref({});
const teleportTarget = ref('body');

const resolveTeleportTarget = () => {
  const overlayElement = comboboxRef.value?.closest('dialog[open], .modal-mask');
  teleportTarget.value = overlayElement || 'body';
};

const updateDropdownPosition = () => {
  if (!open.value || !comboboxRef.value) return;

  const rect = comboboxRef.value.getBoundingClientRect();
  const viewportPadding = 8;
  const width = Math.min(rect.width, window.innerWidth - viewportPadding * 2);
  const left = Math.min(
    Math.max(rect.left, viewportPadding),
    window.innerWidth - width - viewportPadding
  );
  const top = Math.max(rect.bottom + 8, viewportPadding);
  const maxHeight = Math.max(window.innerHeight - top - viewportPadding, 160);

  dropdownStyle.value = {
    left: `${Math.round(left)}px`,
    maxHeight: `${Math.round(maxHeight)}px`,
    top: `${Math.round(top)}px`,
    width: `${Math.round(width)}px`,
  };
};

const filteredOptions = computed(() => {
  // For API search, don't filter options locally
  if (props.useApiResults && search.value) {
    return props.options;
  }

  // For local search, filter options based on search term
  const searchTerm = search.value.toLowerCase();
  return props.options.filter(option =>
    option.label.toLowerCase().includes(searchTerm)
  );
});
const selectPlaceholder = computed(() => {
  return props.placeholder || t('COMBOBOX.PLACEHOLDER');
});
const selectedOption = computed(() =>
  props.options.find(option => option.value === selectedValue.value)
);
const selectedLabel = computed(() => {
  return selectedOption.value?.label ?? selectPlaceholder.value;
});
const selectedIcon = computed(() => selectedOption.value?.icon || '');
const triggerColor = computed(() => {
  if (props.hasError && !open.value) return 'ruby';
  if (props.inputLike) return 'slate';
  return open.value ? 'blue' : 'slate';
});

const hasAppendSlot = computed(() => !!slots.append);

const triggerClass = computed(() => [
  'w-full !px-3 text-n-slate-12 font-normal focus:outline-n-brand',
  props.inputLike
    ? '!h-10 !rounded-lg !bg-n-alpha-black2 !py-2.5 !outline-n-weak hover:!outline-n-slate-6 dark:hover:!outline-n-slate-6'
    : '!py-2.5 group-hover/combobox:border-n-slate-6',
  hasAppendSlot.value ? '!pr-[4.25rem]' : '!pr-10',
  {
    focused: open.value,
    '[&:not(.focused)]:dark:outline-n-weak [&:not(.focused)]:hover:enabled:outline-n-slate-6 [&:not(.focused)]:dark:hover:enabled:outline-n-slate-6':
      !props.hasError && !props.inputLike,
  },
]);

const selectOption = option => {
  if (selectedValue.value === option.value) {
    selectedValue.value = '';
    emit('update:modelValue', '');
  } else {
    selectedValue.value = option.value;
    emit('update:modelValue', option.value);
  }
  open.value = false;
  search.value = '';
};

const toggleDropdown = () => {
  if (props.disabled) return;
  open.value = !open.value;
  if (open.value) {
    resolveTeleportTarget();
    search.value = '';
    nextTick(() => {
      updateDropdownPosition();
      dropdownRef.value?.focus();
    });
  }
};

watch(
  () => props.modelValue,
  newValue => {
    selectedValue.value = newValue;
  }
);

watch(
  () => props.options,
  () => {
    if (!open.value) return;
    nextTick(() => updateDropdownPosition());
  },
  { deep: true }
);

useEventListener(window, 'resize', updateDropdownPosition);
useEventListener(window, 'scroll', updateDropdownPosition, {
  capture: true,
  passive: true,
});
</script>

<template>
  <div
    ref="comboboxRef"
    class="relative w-full min-w-0"
    :class="{
      'cursor-not-allowed': disabled,
      'group/combobox': !disabled,
    }"
    @click.prevent
  >
    <OnClickOutside
      :options="{ ignore: ['.dashboard-combobox-dropdown'] }"
      @trigger="open = false"
    >
      <div class="relative">
        <Button
          variant="outline"
          :color="triggerColor"
          justify="start"
          :disabled="disabled"
          no-animation
          :class="triggerClass"
          @click="toggleDropdown"
        >
          <span
            class="flex min-w-0 flex-1 items-center justify-start gap-2 pr-2 text-left"
          >
            <span
              v-if="selectedIcon"
              class="size-4 shrink-0 text-n-slate-10"
              :class="selectedIcon"
              aria-hidden="true"
            />
            <span
              class="min-w-0 flex-1 truncate text-left"
              :class="selectedOption ? 'text-n-slate-12' : 'text-n-slate-10'"
            >
              {{ selectedLabel }}
            </span>
          </span>
        </Button>

        <span
          class="pointer-events-none absolute inset-y-0 right-3 z-10 my-auto inline-flex size-4 items-center justify-center text-n-slate-10"
          :class="[open ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down']"
          aria-hidden="true"
        />

        <div
          v-if="hasAppendSlot"
          class="absolute inset-y-0 right-9 z-10 flex items-center"
          @click.stop
        >
          <slot name="append" />
        </div>
      </div>

      <ComboBoxDropdown
        ref="dropdownRef"
        v-model:search-value="search"
        :teleport-target="teleportTarget"
        :open="open"
        :options="filteredOptions"
        :search-placeholder="searchPlaceholder"
        :empty-state="emptyState"
        :selected-values="selectedValue"
        :dropdown-style="dropdownStyle"
        @search="emit('search', $event)"
        @select="selectOption"
      />

      <p
        v-if="message"
        class="mt-2 mb-0 text-xs truncate transition-all duration-500 ease-in-out"
        :class="{
          'text-n-ruby-9': hasError,
          'text-n-slate-11': !hasError,
        }"
      >
        {{ message }}
      </p>
    </OnClickOutside>
  </div>
</template>
