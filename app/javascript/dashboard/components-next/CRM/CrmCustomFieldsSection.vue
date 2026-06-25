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
  layout: {
    type: String,
    default: 'grid',
    validator: value => ['grid', 'rows'].includes(value),
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
const isRowsLayout = computed(() => props.layout === 'rows');

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
    <div v-if="isRowsLayout" class="crm-custom-fields-section-rows">
      <template v-for="definition in visibleDefinitions" :key="definition.id">
        <div
          v-if="definition.fieldType === 'checkbox'"
          class="crm-custom-fields-section-row"
        >
          <div class="crm-custom-fields-section-label-block">
            <span class="crm-custom-fields-section-label">
              {{ definition.label }}
            </span>
            <span
              v-if="definition.description"
              class="crm-custom-fields-section-description"
            >
              {{ definition.description }}
            </span>
          </div>
          <div
            class="crm-custom-fields-section-control crm-custom-fields-section-checkbox-control"
          >
            <Checkbox
              :model-value="resolvedValue(definition)"
              @update:model-value="updateValue(definition.key, $event)"
            />
          </div>
        </div>

        <div
          v-else-if="definition.fieldType === 'textarea'"
          class="crm-custom-fields-section-row crm-custom-fields-section-row--start"
        >
          <div class="crm-custom-fields-section-label-block">
            <span class="crm-custom-fields-section-label">
              {{ definition.label }}
            </span>
            <span
              v-if="definition.description"
              class="crm-custom-fields-section-description"
            >
              {{ definition.description }}
            </span>
          </div>
          <TextArea
            :model-value="resolvedValue(definition)"
            auto-height
            class="crm-custom-fields-section-control crm-custom-fields-section-textarea-control"
            custom-text-area-wrapper-class="!rounded-md !border-n-weak !bg-n-alpha-black2 !px-2 !py-1 hover:!border-n-slate-6"
            min-height="3rem"
            @update:model-value="updateValue(definition.key, $event)"
          />
        </div>

        <div
          v-else-if="definition.fieldType === 'date'"
          class="crm-custom-fields-section-row"
        >
          <div class="crm-custom-fields-section-label-block">
            <span class="crm-custom-fields-section-label">
              {{ definition.label }}
            </span>
            <span
              v-if="definition.description"
              class="crm-custom-fields-section-description"
            >
              {{ definition.description }}
            </span>
          </div>
          <SchedulingDateTimeField
            class="crm-custom-fields-section-control crm-custom-fields-section-date-control"
            :model-value="resolvedValue(definition)"
            type="date"
            @update:model-value="updateValue(definition.key, $event)"
          />
        </div>

        <div
          v-else-if="definition.fieldType === 'datetime'"
          class="crm-custom-fields-section-row"
        >
          <div class="crm-custom-fields-section-label-block">
            <span class="crm-custom-fields-section-label">
              {{ definition.label }}
            </span>
            <span
              v-if="definition.description"
              class="crm-custom-fields-section-description"
            >
              {{ definition.description }}
            </span>
          </div>
          <SchedulingDateTimeField
            class="crm-custom-fields-section-control crm-custom-fields-section-date-control"
            :model-value="resolvedValue(definition)"
            type="datetime"
            @update:model-value="updateValue(definition.key, $event)"
          />
        </div>

        <div
          v-else-if="definition.fieldType === 'select'"
          class="crm-custom-fields-section-row"
        >
          <div class="crm-custom-fields-section-label-block">
            <span class="crm-custom-fields-section-label">
              {{ definition.label }}
            </span>
            <span
              v-if="definition.description"
              class="crm-custom-fields-section-description"
            >
              {{ definition.description }}
            </span>
          </div>
          <SchedulingSelectField
            class="crm-custom-fields-section-control crm-custom-fields-section-select-control"
            :model-value="resolvedValue(definition)"
            :options="optionList(definition)"
            @update:model-value="updateValue(definition.key, $event)"
          />
        </div>

        <div
          v-else-if="definition.fieldType === 'multiselect'"
          class="crm-custom-fields-section-row crm-custom-fields-section-row--start"
        >
          <div class="crm-custom-fields-section-label-block">
            <span class="crm-custom-fields-section-label">
              {{ definition.label }}
            </span>
            <span
              v-if="definition.description"
              class="crm-custom-fields-section-description"
            >
              {{ definition.description }}
            </span>
          </div>
          <TagMultiSelectComboBox
            class="crm-custom-fields-section-control crm-custom-fields-section-multi-control"
            :model-value="resolvedValue(definition)"
            :options="optionList(definition)"
            @update:model-value="updateValue(definition.key, $event)"
          />
        </div>

        <div v-else class="crm-custom-fields-section-row">
          <div class="crm-custom-fields-section-label-block">
            <span class="crm-custom-fields-section-label">
              {{ definition.label }}
            </span>
            <span
              v-if="definition.description"
              class="crm-custom-fields-section-description"
            >
              {{ definition.description }}
            </span>
          </div>
          <Input
            class="crm-custom-fields-section-control crm-custom-fields-section-input-control"
            :model-value="resolvedValue(definition)"
            :type="
              ['currency', 'number', 'percent'].includes(definition.fieldType)
                ? 'number'
                : 'text'
            "
            :step="numericStep(definition)"
            @update:model-value="updateValue(definition.key, $event)"
          />
        </div>
      </template>
    </div>

    <div v-else class="grid gap-4 md:grid-cols-2">
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

<style scoped>
.crm-custom-fields-section-rows {
  @apply grid gap-2 border-t border-n-weak pt-3;
}

.crm-custom-fields-section-row {
  display: grid;
  gap: 0.375rem;
  min-width: 0;
}

.crm-custom-fields-section-label-block {
  @apply grid min-w-0 gap-1;
}

.crm-custom-fields-section-label {
  @apply mb-0 min-w-0 text-xs font-medium leading-4 text-n-slate-11;
}

.crm-custom-fields-section-description {
  @apply text-[11px] leading-4 text-n-slate-10;
}

.crm-custom-fields-section-control {
  width: 100%;
  min-width: 0;
}

.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-input-control input),
.crm-custom-fields-section-rows
  :deep(
    .crm-custom-fields-section-date-control .reka-date-time-picker__trigger
  ),
.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-select-control button),
.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-multi-control button) {
  @apply border border-n-weak bg-n-alpha-black2 text-sm font-normal text-n-slate-12 shadow-none outline outline-1 outline-transparent transition-colors duration-150 !important;
  border-radius: 0.375rem !important;
  min-height: 2rem !important;
}

.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-input-control input),
.crm-custom-fields-section-rows
  :deep(
    .crm-custom-fields-section-date-control .reka-date-time-picker__trigger
  ),
.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-select-control button) {
  height: 2rem !important;
}

.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-input-control input) {
  @apply px-2 py-1 !important;
}

.crm-custom-fields-section-rows
  :deep(
    .crm-custom-fields-section-date-control .reka-date-time-picker__trigger
  ),
.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-select-control button),
.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-multi-control button) {
  @apply justify-start py-1 !important;
}

.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-input-control input:hover),
.crm-custom-fields-section-rows
  :deep(
    .crm-custom-fields-section-date-control
      .reka-date-time-picker__trigger:hover
  ),
.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-select-control button:hover),
.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-multi-control button:hover) {
  @apply border-n-slate-6 bg-n-alpha-black2 outline-transparent !important;
}

.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-input-control input:focus),
.crm-custom-fields-section-rows
  :deep(
    .crm-custom-fields-section-date-control
      .reka-date-time-picker__trigger:focus
  ),
.crm-custom-fields-section-rows
  :deep(
    .crm-custom-fields-section-date-control
      .reka-date-time-picker__trigger[data-state='open']
  ),
.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-select-control button:focus),
.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-select-control button[data-state='open']),
.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-multi-control button:focus),
.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-multi-control button[data-state='open']) {
  @apply border-n-weak bg-n-alpha-black2 outline-n-brand !important;
}

.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-textarea-control textarea) {
  @apply text-sm font-normal text-n-slate-12 !important;
}

.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-multi-control button) {
  height: auto !important;
  min-height: 2rem !important;
}

.crm-custom-fields-section-rows
  :deep(.crm-custom-fields-section-multi-control button > div) {
  @apply rounded-md bg-n-alpha-black1 px-1.5 py-0.5 !important;
}

.crm-custom-fields-section-checkbox-control {
  @apply flex min-h-8 items-center;
}

@media (min-width: 768px) {
  .crm-custom-fields-section-row {
    align-items: center;
    grid-template-columns: minmax(6.5rem, 1fr) minmax(8rem, 14rem);
  }

  .crm-custom-fields-section-row--start {
    align-items: start;
  }

  .crm-custom-fields-section-row--start
    > .crm-custom-fields-section-label-block {
    padding-top: 0.5rem;
  }
}
</style>
