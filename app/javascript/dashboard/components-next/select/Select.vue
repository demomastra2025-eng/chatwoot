<script setup>
import { computed, getCurrentInstance, useAttrs } from 'vue';
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

const inputId = computed(() => props.id || `select-${uid}`);
const selectAttrs = computed(() => {
  const { class: _class, style: _style, ...rest } = attrs;
  return rest;
});
const hasStructuredOptions = computed(
  () => props.groups.length > 0 || props.options.length > 0
);
const wrapperClasses = computed(() => [
  'relative',
  hasStructuredOptions.value ? ['w-fit', attrs.class] : '',
]);
const selectClasses = computed(() => [
  'appearance-none [background-image:none] rounded-lg border-0 bg-n-surface-1 !mb-0 py-2 pl-3 pr-10 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] transition-all duration-200',
  !props.error && !props.disabled
    ? 'outline-n-weak hover:outline-n-slate-6 focus:outline-n-brand'
    : '',
  props.error && !props.disabled ? 'outline-n-red-9 focus:outline-n-red-9' : '',
  props.disabled
    ? 'cursor-not-allowed bg-n-slate-2 opacity-60 outline-n-weak'
    : '',
  hasStructuredOptions.value ? 'w-full' : '',
  !hasStructuredOptions.value ? attrs.class : '',
]);
</script>

<template>
  <div :class="wrapperClasses">
    <select
      :id="inputId"
      v-model="modelValue"
      v-bind="selectAttrs"
      :disabled="disabled"
      :class="selectClasses"
      :style="attrs.style"
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
      class="pointer-events-none absolute inset-y-0 right-0 flex items-center pr-3"
    >
      <Icon
        icon="i-lucide-chevron-down"
        class="size-4 text-n-slate-11"
        :class="{ 'opacity-50': disabled }"
      />
    </div>
  </div>
</template>
