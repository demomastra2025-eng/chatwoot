<script setup>
import { ref, computed, watch, nextTick, useAttrs } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';
import { useI18n } from 'vue-i18n';

import ComboBoxDropdown from 'dashboard/components-next/combobox/ComboBoxDropdown.vue';

const props = defineProps({
  options: {
    type: Array,
    required: true,
    validator: value =>
      value.every(option => 'value' in option && 'label' in option),
  },
  placeholder: {
    type: String,
    default: '',
  },
  modelValue: {
    type: Array,
    default: () => [],
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  searchPlaceholder: {
    type: String,
    default: '',
  },
  emptyState: {
    type: String,
    default: '',
  },
  message: {
    type: String,
    default: '',
  },
  hasError: {
    type: Boolean,
    default: false,
  },
  id: {
    type: String,
    default: '',
  },
  useApiResults: {
    type: Boolean,
    default: false,
  },
  dropdownPlacement: {
    type: String,
    default: 'bottom',
    validator: value => ['auto', 'bottom', 'top'].includes(value),
  },
});

const emit = defineEmits(['open', 'search', 'update:modelValue']);

const { t } = useI18n();
const attrs = useAttrs();

defineOptions({
  inheritAttrs: false,
});

const selectedValues = ref(props.modelValue);
const open = ref(false);
const search = ref('');
const dropdownRef = ref(null);
const comboboxRef = ref(null);
const dropdownStyle = ref({});
const teleportTarget = ref('body');

const resolveTeleportTarget = () => {
  const overlayElement = comboboxRef.value?.closest(
    'dialog[open], .modal-mask'
  );
  teleportTarget.value = overlayElement || 'body';
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
  const availableAbove = Math.max(
    rect.top - viewportPadding - dropdownGap,
    160
  );
  const availableBelow = Math.max(
    window.innerHeight - rect.bottom - viewportPadding - dropdownGap,
    160
  );
  const placement = resolveDropdownPlacement({
    availableAbove,
    availableBelow,
  });

  dropdownStyle.value = {
    bottom:
      placement === 'top'
        ? `${Math.round(window.innerHeight - rect.top + dropdownGap)}px`
        : 'auto',
    left: `${Math.round(left)}px`,
    maxHeight: `${Math.round(
      placement === 'top' ? availableAbove : availableBelow
    )}px`,
    top:
      placement === 'bottom'
        ? `${Math.round(rect.bottom + dropdownGap)}px`
        : 'auto',
    width: `${Math.round(width)}px`,
  };
};

const filteredOptions = computed(() => {
  if (props.useApiResults && search.value) {
    return props.options;
  }

  const searchTerm = search.value.toLowerCase();
  return props.options.filter(option =>
    option.label?.toLowerCase().includes(searchTerm)
  );
});

const selectPlaceholder = computed(() => {
  return props.placeholder || t('COMBOBOX.PLACEHOLDER');
});
const triggerId = computed(() => props.id || attrs.id || undefined);
const rootAttrs = computed(() => {
  const forwardedAttrs = { ...attrs };
  delete forwardedAttrs.class;
  delete forwardedAttrs.style;
  delete forwardedAttrs.id;
  return forwardedAttrs;
});

const selectedTags = computed(() => {
  return selectedValues.value.map(value => {
    const option = props.options.find(opt => opt.value === value);
    return option || { value, label: value };
  });
});

const toggleOption = option => {
  const index = selectedValues.value.indexOf(option.value);
  if (index === -1) {
    selectedValues.value.push(option.value);
  } else {
    selectedValues.value.splice(index, 1);
  }
  emit('update:modelValue', selectedValues.value);
};

const removeTag = value => {
  const index = selectedValues.value.indexOf(value);
  if (index !== -1) {
    selectedValues.value.splice(index, 1);
    emit('update:modelValue', selectedValues.value);
  }
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
    selectedValues.value = newValue;
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

defineExpose({
  toggleDropdown,
  open,
  disabled: props.disabled,
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
      <button
        :id="triggerId"
        type="button"
        class="flex flex-wrap w-full gap-2 px-3 py-2.5 border rounded-lg cursor-pointer bg-n-alpha-black2 min-h-[42px] transition-all duration-500 ease-in-out"
        :class="{
          'border-n-ruby-8': hasError,
          'border-n-weak dark:border-n-weak hover:border-n-slate-6 dark:hover:border-n-slate-6':
            !hasError && !open,
          'border-n-brand': open,
          'cursor-not-allowed pointer-events-none opacity-50': disabled,
        }"
        :disabled="disabled"
        @click="toggleDropdown"
      >
        <div
          v-for="tag in selectedTags"
          :key="tag.value"
          class="flex items-center justify-center max-w-full gap-1 px-2 py-0.5 rounded-lg bg-n-alpha-black1"
          @click.stop
        >
          <span class="flex-grow min-w-0 text-sm truncate text-n-slate-12">
            {{ tag.label }}
          </span>
          <span
            class="flex-shrink-0 cursor-pointer i-lucide-x size-3 text-n-slate-11"
            @click="removeTag(tag.value)"
          />
        </div>
        <span
          v-if="selectedTags.length === 0"
          class="flex items-center text-sm text-n-slate-11"
        >
          {{ selectPlaceholder }}
        </span>
      </button>

      <ComboBoxDropdown
        ref="dropdownRef"
        v-model:search-value="search"
        :teleport-target="teleportTarget"
        :open="open"
        :options="filteredOptions"
        :search-placeholder="searchPlaceholder"
        :empty-state="emptyState"
        multiple
        :selected-values="selectedValues"
        :dropdown-style="dropdownStyle"
        @search="emit('search', $event)"
        @select="toggleOption"
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
