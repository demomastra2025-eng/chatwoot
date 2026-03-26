<script setup>
import { computed } from 'vue';

import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

const props = defineProps({
  description: {
    type: String,
    default: '',
  },
  definitions: {
    type: Array,
    default: () => [],
  },
  modelValue: {
    type: Object,
    default: () => ({}),
  },
  framed: {
    type: Boolean,
    default: true,
  },
  title: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['update:modelValue']);

const visibleDefinitions = computed(() =>
  props.definitions.filter(definition => definition.active !== false)
);

const optionList = definition => {
  return (definition.options || []).map(option => {
    if (typeof option === 'string') {
      return {
        label: option,
        value: option,
      };
    }

    return {
      label: option.label || option.value,
      value: option.value,
    };
  });
};

const numericStep = definition => {
  return ['currency', 'number', 'percent'].includes(definition.fieldType)
    ? 'any'
    : undefined;
};

const resolvedValue = definition => {
  const value = props.modelValue?.[definition.key];

  if (definition.fieldType === 'checkbox') {
    return Boolean(value);
  }

  if (definition.fieldType === 'multiselect') {
    return Array.isArray(value) ? value : [];
  }

  return value ?? '';
};

const updateValue = (key, value) => {
  const nextValue = { ...(props.modelValue || {}) };

  if (
    value === '' ||
    value === null ||
    value === undefined ||
    (Array.isArray(value) && value.length === 0)
  ) {
    delete nextValue[key];
  } else {
    nextValue[key] = value;
  }

  emit('update:modelValue', nextValue);
};
</script>

<template>
  <SchedulingFormFieldGroup
    v-show="visibleDefinitions.length"
    :title="title"
    :description="description"
    :framed="framed"
  >
    <div class="grid gap-4 md:grid-cols-2">
      <template v-for="definition in visibleDefinitions" :key="definition.id">
        <div
          v-if="definition.fieldType === 'checkbox'"
          class="flex items-start gap-3 rounded-xl bg-n-alpha-black2 px-3 py-3 outline outline-1 outline-n-weak md:col-span-2"
        >
          <Checkbox
            :model-value="resolvedValue(definition)"
            @update:model-value="updateValue(definition.key, $event)"
          />
          <div class="grid gap-1">
            <span class="text-sm font-medium text-n-slate-12">
              {{ definition.label }}
            </span>
            <span v-if="definition.description" class="text-xs text-n-slate-11">
              {{ definition.description }}
            </span>
          </div>
        </div>

        <TextArea
          v-else-if="definition.fieldType === 'textarea'"
          :label="definition.label"
          :message="definition.description"
          :model-value="resolvedValue(definition)"
          auto-height
          class="md:col-span-2"
          @update:model-value="updateValue(definition.key, $event)"
        />

        <SchedulingDateTimeField
          v-else-if="definition.fieldType === 'date'"
          :label="definition.label"
          :message="definition.description"
          :model-value="resolvedValue(definition)"
          type="date"
          @update:model-value="updateValue(definition.key, $event)"
        />

        <SchedulingDateTimeField
          v-else-if="definition.fieldType === 'datetime'"
          :label="definition.label"
          :message="definition.description"
          :model-value="resolvedValue(definition)"
          type="datetime"
          @update:model-value="updateValue(definition.key, $event)"
        />

        <SchedulingSelectField
          v-else-if="definition.fieldType === 'select'"
          :label="definition.label"
          :message="definition.description"
          :model-value="resolvedValue(definition)"
          :options="optionList(definition)"
          @update:model-value="updateValue(definition.key, $event)"
        />

        <div
          v-else-if="definition.fieldType === 'multiselect'"
          class="grid gap-1"
        >
          <span class="mb-0.5 text-sm font-medium text-n-slate-12">
            {{ definition.label }}
          </span>
          <TagMultiSelectComboBox
            :model-value="resolvedValue(definition)"
            :options="optionList(definition)"
            @update:model-value="updateValue(definition.key, $event)"
          />
          <span v-if="definition.description" class="text-xs text-n-slate-11">
            {{ definition.description }}
          </span>
        </div>

        <Input
          v-else
          :label="definition.label"
          :message="definition.description"
          :model-value="resolvedValue(definition)"
          :type="
            ['currency', 'number', 'percent'].includes(definition.fieldType)
              ? 'number'
              : 'text'
          "
          :step="numericStep(definition)"
          @update:model-value="updateValue(definition.key, $event)"
        />
      </template>
    </div>
  </SchedulingFormFieldGroup>
</template>
