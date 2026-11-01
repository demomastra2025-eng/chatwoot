<script setup>
import { computed, getCurrentInstance, ref, useAttrs } from 'vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  id: {
    type: String,
    default: '',
  },
  options: {
    type: Array,
    default: () => [],
    validator: options =>
      options.every(
        opt => typeof opt === 'object' && 'value' in opt && 'label' in opt
      ),
  },
  groups: {
    type: Array,
    default: () => [],
    validator: groups =>
      groups.every(
        group =>
          'label' in group &&
          Array.isArray(group.options) &&
          group.options.every(opt => 'value' in opt && 'label' in opt)
      ),
  },
  placeholder: {
    type: String,
    default: '',
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  error: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['change', 'blur', 'focus']);

const modelValue = defineModel('modelValue', {
  type: [String, Number, Boolean, Array, Object],
  default: '',
});

defineOptions({
  inheritAttrs: false,
});

const { uid } = getCurrentInstance();
const attrs = useAttrs();
const isOpen = ref(false);

const inputId = computed(() => props.id || `select-${uid}`);
const selectAttrs = computed(() => {
  const { class: _class, style: _style, ...rest } = attrs;
  return rest;
});
const hasStructuredOptions = computed(
  () => props.groups.length > 0 || props.options.length > 0
);
const hasOptionIcons = computed(
  () =>
    props.options.length > 0 &&
    props.options.some(option => Boolean(option?.icon))
);
const selectedOption = computed(() =>
  props.options.find(option => option.value === modelValue.value)
);
const wrapperClasses = computed(() => [
  'relative',
  hasStructuredOptions.value ? ['w-fit', attrs.class] : '',
]);
const selectClasses = computed(() => [
  'appearance-none [background-image:none] rounded-lg border-0 bg-n-surface-1 !mb-0 py-2 pr-10 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] transition-all duration-200',
  selectedOption.value?.icon ? 'pl-9' : 'pl-3',
  !props.error && !props.disabled
    ? 'outline-n-weak hover:outline-n-slate-6 focus:outline-n-brand'
    : '',
  props.error && !props.disabled
    ? 'outline-n-ruby-9 focus:outline-n-ruby-9'
    : '',
  props.disabled
    ? 'cursor-not-allowed bg-n-slate-2 opacity-60 outline-n-weak'
    : '',
  hasStructuredOptions.value ? 'w-full' : '',
  !hasStructuredOptions.value ? attrs.class : '',
]);

const closeMenu = () => {
  isOpen.value = false;
};

const toggleMenu = () => {
  if (props.disabled) return;
  isOpen.value = !isOpen.value;
};

const selectOption = option => {
  if (props.disabled || option?.disabled) return;
  modelValue.value = option.value;
  isOpen.value = false;
  emit('change', { target: { value: option.value } });
};
</script>

<template>
  <div v-on-clickaway="closeMenu" :class="wrapperClasses">
    <button
      v-if="hasOptionIcons"
      type="button"
      :disabled="disabled"
      class="flex w-full items-center justify-between gap-2 rounded-lg border-0 bg-n-surface-1 py-2 pl-3 pr-2.5 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] transition-all duration-200"
      :class="[
        !error && !disabled
          ? 'outline-n-weak hover:outline-n-slate-6 focus:outline-n-brand'
          : '',
        error && !disabled ? 'outline-n-ruby-9 focus:outline-n-ruby-9' : '',
        disabled
          ? 'cursor-not-allowed bg-n-slate-2 opacity-60 outline-n-weak'
          : '',
      ]"
      :style="attrs.style"
      data-test="select-icon-trigger"
      @click="toggleMenu"
    >
      <span class="flex min-w-0 flex-1 items-center gap-2 text-left">
        <Icon
          v-if="selectedOption?.icon"
          :icon="selectedOption.icon"
          class="size-4 shrink-0"
          :class="selectedOption.iconClass || 'text-n-slate-12'"
        />
        <span class="min-w-0 flex-1 truncate">
          {{ selectedOption?.label || placeholder }}
        </span>
      </span>
      <Icon
        icon="i-lucide-chevron-down"
        class="size-4 shrink-0 text-n-slate-11 transition-transform duration-150"
        :class="{ 'rotate-180': isOpen, 'opacity-50': disabled }"
      />
    </button>

    <div
      v-if="hasOptionIcons && isOpen"
      role="listbox"
      class="absolute left-0 right-0 top-full z-40 mt-1 flex max-h-64 flex-col gap-0.5 overflow-y-auto rounded-lg border border-n-weak bg-n-solid-2 p-1 shadow-lg dark:border-n-strong/50"
      data-test="select-icon-menu"
    >
      <button
        v-for="option in options"
        :key="option.value"
        type="button"
        role="option"
        :disabled="option.disabled"
        :aria-selected="option.value === modelValue"
        class="flex w-full items-center justify-between gap-2 rounded-md px-2.5 py-1.5 text-left text-sm text-n-slate-12 transition-colors hover:bg-n-alpha-2 disabled:cursor-not-allowed disabled:opacity-50"
        :class="{ 'bg-n-alpha-2 font-medium': option.value === modelValue }"
        @click="selectOption(option)"
      >
        <span class="flex min-w-0 flex-1 items-center gap-2">
          <Icon
            v-if="option.icon"
            :icon="option.icon"
            class="size-4 shrink-0"
            :class="option.iconClass || 'text-n-slate-12'"
          />
          <span class="min-w-0 flex-1 truncate">{{ option.label }}</span>
        </span>
        <Icon
          v-if="option.value === modelValue"
          icon="i-lucide-check"
          class="size-4 shrink-0 text-n-slate-12"
        />
      </button>
    </div>

    <select
      :id="inputId"
      v-model="modelValue"
      v-bind="selectAttrs"
      :disabled="disabled"
      :class="hasOptionIcons ? 'sr-only' : selectClasses"
      :style="hasOptionIcons ? undefined : attrs.style"
      @change="emit('change', $event)"
      @blur="emit('blur', $event)"
      @focus="emit('focus', $event)"
    >
      <option v-if="placeholder && hasStructuredOptions" value="" disabled>
        {{ placeholder }}
      </option>
      <template v-if="groups.length">
        <optgroup
          v-for="group in groups"
          :key="group.label"
          :label="group.label"
        >
          <option
            v-for="option in group.options"
            :key="option.value"
            :value="option.value"
            :disabled="option.disabled"
          >
            {{ option.label }}
          </option>
        </optgroup>
      </template>
      <template v-else-if="options.length">
        <option
          v-for="option in options"
          :key="option.value"
          :value="option.value"
          :disabled="option.disabled"
        >
          {{ option.label }}
        </option>
      </template>
      <slot v-else />
    </select>
    <div
      v-if="!hasOptionIcons"
      class="pointer-events-none absolute inset-y-0 right-0 flex items-start py-3 pr-2"
    >
      <Icon
        icon="i-lucide-chevron-down"
        class="size-4 text-n-slate-11"
        :class="{ 'opacity-50': disabled }"
      />
    </div>
  </div>
</template>
