<script setup>
import { ref, computed, watch, nextTick, useSlots, useAttrs } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
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
  id: { type: String, default: '' },
  dropdownPlacement: {
    type: String,
    default: 'bottom',
    validator: value => ['auto', 'bottom', 'top'].includes(value),
  },
});

const emit = defineEmits(['open', 'update:modelValue', 'search']);

const { t } = useI18n();
const slots = useSlots();
const attrs = useAttrs();

defineOptions({
  inheritAttrs: false,
});

const selectedValue = ref(props.modelValue);
const open = ref(false);
const search = ref('');
const dropdownRef = ref(null);
const comboboxRef = ref(null);
const dropdownStyle = ref({});
const teleportTarget = ref('body');

const resolveTeleportTarget = () => {
  const dialogElement = comboboxRef.value?.closest('dialog[open]');
  teleportTarget.value = dialogElement || 'body';
};

const resolveDropdownPlacement = ({ availableAbove, availableBelow }) => {
  if (props.dropdownPlacement !== 'auto') {
    return props.dropdownPlacement;
  }

  return availableAbove > availableBelow ? 'top' : 'bottom';
};

const updateDropdownPosition = () => {
  if (!open.value || !comboboxRef.value) return;

  const rect = comboboxRef.value.getBoundingClientRect();
  const viewportPadding = 8;
  const dropdownGap = 8;
  const width = Math.min(rect.width, window.innerWidth - viewportPadding * 2);
  const left = Math.min(
    Math.max(rect.left, viewportPadding),
    window.innerWidth - width - viewportPadding
  );
  const availableAbove = Math.max(rect.top - viewportPadding - dropdownGap, 0);
  const availableBelow = Math.max(
    window.innerHeight - rect.bottom - viewportPadding - dropdownGap,
    0
  );
  const placement = resolveDropdownPlacement({
    availableAbove,
    availableBelow,
  });
  const maxHeight = Math.max(
    Math.min(placement === 'top' ? availableAbove : availableBelow, 320),
    96
  );

  dropdownStyle.value = {
    bottom:
      placement === 'top'
        ? `${Math.round(window.innerHeight - rect.top + dropdownGap)}px`
        : 'auto',
    left: `${Math.round(left)}px`,
    maxHeight: `${Math.round(maxHeight)}px`,
    top:
      placement === 'bottom'
        ? `${Math.round(rect.bottom + dropdownGap)}px`
        : 'auto',
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
const selectedIconClass = computed(
  () => selectedOption.value?.iconClass || 'text-n-slate-10'
);
const selectedLabelClass = computed(() => {
  if (!selectedOption.value) return 'text-n-slate-10';
  return selectedOption.value.labelClass || 'text-n-slate-12';
});
const triggerId = computed(() => props.id || attrs.id || undefined);
const rootAttrs = computed(() => {
  const forwardedAttrs = { ...attrs };
  delete forwardedAttrs.class;
  delete forwardedAttrs.style;
  delete forwardedAttrs.id;
  return forwardedAttrs;
});
const triggerColor = computed(() => {
  if (props.hasError && !open.value) return 'ruby';
  if (props.inputLike) return 'slate';
  return open.value ? 'blue' : 'slate';
});

const hasAppendSlot = computed(() => !!slots.append);

const triggerClass = computed(() => [
  'w-full !px-2 text-n-slate-12 font-normal focus:outline-n-brand',
  props.inputLike
    ? '!h-10 !rounded-lg !bg-n-alpha-black2 !py-2.5 !outline-n-weak hover:!outline-n-slate-6 dark:hover:!outline-n-slate-6'
    : '!py-2.5 group-hover/combobox:border-n-slate-6',
  hasAppendSlot.value ? '!pr-[4.25rem]' : '!pr-2',
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
    emit('open');
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
    v-bind="rootAttrs"
    class="relative w-full min-w-0"
    :class="[
      attrs.class,
      {
        'cursor-not-allowed': disabled,
        'group/combobox': !disabled,
      },
    ]"
    :style="attrs.style"
    @click.prevent
  >
    <OnClickOutside
      :options="{ ignore: ['.dashboard-combobox-dropdown'] }"
      @trigger="open = false"
    >
      <div class="relative">
        <Button
          :id="triggerId"
          :aria-label="attrs['aria-label']"
          variant="outline"
          :color="triggerColor"
          justify="start"
          :disabled="disabled"
          no-animation
          :class="triggerClass"
          @click="toggleDropdown"
        >
          <span
            class="flex min-w-0 flex-1 items-center justify-start gap-2 text-left"
          >
            <Avatar
              v-if="selectedOption?.thumbnail"
              :name="selectedOption.thumbnail.name || selectedLabel"
              :src="selectedOption.thumbnail.src"
              :size="18"
              rounded-full
            />
            <span
              v-else-if="selectedOption?.stageColor"
              class="h-5 w-1 shrink-0 rounded-full"
              :style="{ backgroundColor: selectedOption.stageColor }"
              aria-hidden="true"
            />
            <span
              v-if="selectedIcon"
              class="size-4 shrink-0"
              :class="[selectedIcon, selectedIconClass]"
              aria-hidden="true"
            />
            <span
              class="min-w-0 flex-1 truncate text-left"
              :class="selectedLabelClass"
            >
              {{ selectedLabel }}
            </span>
            <span
              class="size-4 shrink-0 text-n-slate-10"
              :class="[open ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down']"
              aria-hidden="true"
            />
          </span>
        </Button>

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
