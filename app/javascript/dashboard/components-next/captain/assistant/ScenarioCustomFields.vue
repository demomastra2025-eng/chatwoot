<script setup>
import { useI18n } from 'vue-i18n';

const props = defineProps({
  modelValue: { type: Object, default: () => ({}) },
  fields: { type: Array, default: () => [] },
  disabled: { type: Boolean, default: false },
});
const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();
const update = (field, value) =>
  emit('update:modelValue', { ...props.modelValue, [field.key]: value });
const optionValue = option =>
  typeof option === 'object' ? option.value : option;
const optionLabel = option =>
  typeof option === 'object' ? option.label : option;
const inputType = field =>
  ({
    number: 'number',
    currency: 'number',
    percent: 'number',
    date: 'date',
    url: 'url',
  })[field.field_type] || 'text';
const numeric = field =>
  ['number', 'currency', 'percent'].includes(field.field_type);
const inputClass =
  'mb-0 w-full rounded-lg border border-n-weak bg-n-background px-2 py-1.5 text-sm';
</script>

<template>
  <div
    v-if="fields.length"
    class="grid gap-3 sm:grid-cols-2"
    data-test="scenario-custom-fields"
  >
    <label
      v-for="field in fields"
      :key="field.key"
      class="flex flex-col gap-1 text-xs text-n-slate-11"
    >
      <span>{{ field.label }} <span v-if="field.required">*</span></span>
      <select
        v-if="['select', 'multiselect'].includes(field.field_type)"
        :class="inputClass"
        :multiple="field.field_type === 'multiselect'"
        :value="modelValue[field.key] ?? field.default_value"
        :disabled="disabled"
        @change="
          update(
            field,
            field.field_type === 'multiselect'
              ? Array.from($event.target.selectedOptions, item => item.value)
              : $event.target.value
          )
        "
      >
        <option v-if="field.field_type === 'select'" value="">
          {{ t('CAPTAIN.PLAYGROUND.FIELD_EMPTY') }}
        </option>
        <option
          v-for="option in field.options || []"
          :key="optionValue(option)"
          :value="optionValue(option)"
        >
          {{ optionLabel(option) }}
        </option>
      </select>
      <input
        v-else-if="field.field_type === 'checkbox'"
        type="checkbox"
        :checked="modelValue[field.key] ?? field.default_value"
        :disabled="disabled"
        @change="update(field, $event.target.checked)"
      />
      <input
        v-else
        :type="inputType(field)"
        :class="inputClass"
        :value="modelValue[field.key] ?? field.default_value"
        :disabled="disabled"
        @input="
          update(
            field,
            numeric(field) && $event.target.value !== ''
              ? Number($event.target.value)
              : $event.target.value
          )
        "
      />
      <span v-if="field.description">{{ field.description }}</span>
    </label>
  </div>
</template>
