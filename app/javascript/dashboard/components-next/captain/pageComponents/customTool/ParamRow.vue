<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';

const props = defineProps({
  contextFieldOptions: {
    type: Array,
    default: () => [],
  },
  allParamNames: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['remove']);
const { t } = useI18n();
const showErrors = ref(false);
const PARAM_NAME_REGEX = /^[A-Za-z_][A-Za-z0-9_]*$/;
const RESERVED_PARAM_NAMES = [
  'contact',
  'conversation',
  'deal',
  'task',
  'appointment',
  'assistant',
  'account',
  'params',
  'p',
  'visible_fields',
];
const JSON_PARAM_TYPES = ['array', 'object'];

const name = defineModel('name', {
  type: String,
  required: true,
});

const type = defineModel('type', {
  type: String,
  required: true,
});

const description = defineModel('description', {
  type: String,
  default: '',
});

const required = defineModel('required', {
  type: Boolean,
  default: false,
});

const source = defineModel('source', {
  type: String,
  default: 'agent',
});

const contextPath = defineModel('contextPath', {
  type: String,
  default: '',
});

const fixedValue = defineModel('fixedValue', {
  type: String,
  default: '',
});

const requestLocation = defineModel('requestLocation', {
  type: String,
  default: 'template',
});

const requestKey = defineModel('requestKey', {
  type: String,
  default: '',
});

const paramTypeOptions = computed(() => [
  { value: 'string', label: t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_TYPES.STRING') },
  { value: 'number', label: t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_TYPES.NUMBER') },
  {
    value: 'boolean',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_TYPES.BOOLEAN'),
  },
  { value: 'array', label: t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_TYPES.ARRAY') },
  { value: 'object', label: t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_TYPES.OBJECT') },
]);

const paramSourceOptions = computed(() => [
  {
    value: 'agent',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_SOURCES.AGENT'),
  },
  {
    value: 'context',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_SOURCES.CONTEXT'),
  },
  {
    value: 'fixed',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_SOURCES.FIXED'),
  },
]);

const fixedValuePlaceholder = computed(() => {
  if (JSON_PARAM_TYPES.includes(type.value)) {
    return t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_FIXED_VALUE.JSON_PLACEHOLDER');
  }

  return t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_FIXED_VALUE.PLACEHOLDER');
});

const requestLocationOptions = computed(() => [
  {
    value: 'template',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_REQUEST_LOCATIONS.TEMPLATE'),
  },
  {
    value: 'query',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_REQUEST_LOCATIONS.QUERY'),
  },
  {
    value: 'header',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_REQUEST_LOCATIONS.HEADER'),
  },
]);

const hasDuplicateParamName = computed(() => {
  const trimmedName = name.value?.trim();
  if (!trimmedName) {
    return false;
  }

  return (
    props.allParamNames.filter(paramName => paramName?.trim() === trimmedName)
      .length > 1
  );
});

const hasInvalidFixedJsonValue = computed(() => {
  if (
    source.value !== 'fixed' ||
    !JSON_PARAM_TYPES.includes(type.value) ||
    !fixedValue.value
  ) {
    return false;
  }

  try {
    const parsedValue = JSON.parse(fixedValue.value);
    return type.value === 'array'
      ? !Array.isArray(parsedValue)
      : typeof parsedValue !== 'object' ||
          Array.isArray(parsedValue) ||
          parsedValue === null;
  } catch {
    return true;
  }
});

const validationError = computed(() => {
  if (!name.value || name.value.trim() === '') {
    return 'PARAM_NAME_REQUIRED';
  }
  if (!PARAM_NAME_REGEX.test(name.value.trim())) {
    return 'PARAM_NAME_INVALID';
  }
  if (RESERVED_PARAM_NAMES.includes(name.value.trim())) {
    return 'PARAM_NAME_RESERVED';
  }
  if (hasDuplicateParamName.value) {
    return 'PARAM_NAME_DUPLICATE';
  }
  if (
    source.value === 'agent' &&
    (!description.value || description.value.trim() === '')
  ) {
    return 'PARAM_DESCRIPTION_REQUIRED';
  }
  if (source.value === 'context' && !contextPath.value) {
    return 'PARAM_CONTEXT_PATH_REQUIRED';
  }
  if (
    source.value === 'fixed' &&
    (fixedValue.value === '' ||
      fixedValue.value === null ||
      fixedValue.value === undefined)
  ) {
    return 'PARAM_FIXED_VALUE_REQUIRED';
  }
  if (hasInvalidFixedJsonValue.value) {
    return 'PARAM_FIXED_VALUE_JSON_INVALID';
  }
  return null;
});

const validationErrorMessage = computed(() => {
  switch (validationError.value) {
    case 'PARAM_NAME_REQUIRED':
      return t('CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.PARAM_NAME_REQUIRED');
    case 'PARAM_NAME_INVALID':
      return t('CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.PARAM_NAME_INVALID');
    case 'PARAM_NAME_RESERVED':
      return t('CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.PARAM_NAME_RESERVED');
    case 'PARAM_NAME_DUPLICATE':
      return t('CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.PARAM_NAME_DUPLICATE');
    case 'PARAM_DESCRIPTION_REQUIRED':
      return t('CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.PARAM_DESCRIPTION_REQUIRED');
    case 'PARAM_CONTEXT_PATH_REQUIRED':
      return t('CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.PARAM_CONTEXT_PATH_REQUIRED');
    case 'PARAM_FIXED_VALUE_REQUIRED':
      return t('CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.PARAM_FIXED_VALUE_REQUIRED');
    case 'PARAM_FIXED_VALUE_JSON_INVALID':
      return t(
        'CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.PARAM_FIXED_VALUE_JSON_INVALID'
      );
    default:
      return '';
  }
});

watch(
  [
    name,
    type,
    description,
    required,
    source,
    contextPath,
    fixedValue,
    requestLocation,
    requestKey,
  ],
  () => {
    showErrors.value = false;
  }
);

const validate = () => {
  showErrors.value = true;
  return !validationError.value;
};

defineExpose({ validate });
</script>

<template>
  <li class="list-none">
    <div
      class="flex items-start gap-2 p-3 rounded-lg border border-n-weak bg-n-alpha-2"
      :class="{
        'animate-wiggle border-n-ruby-9': showErrors && validationError,
      }"
    >
      <div class="flex flex-col flex-1 gap-3">
        <div class="grid grid-cols-3 gap-2">
          <Input
            v-model="name"
            :placeholder="t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_NAME.PLACEHOLDER')"
            class="col-span-2"
          />
          <ComboBox
            v-model="type"
            :options="paramTypeOptions"
            :placeholder="t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_TYPE.PLACEHOLDER')"
            class="[&>div>button]:bg-n-alpha-black2"
          />
        </div>
        <div class="grid grid-cols-1 gap-2 md:grid-cols-3">
          <ComboBox
            v-model="source"
            :options="paramSourceOptions"
            :placeholder="
              t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_SOURCE.PLACEHOLDER')
            "
            class="[&>div>button]:bg-n-alpha-black2"
          />
          <ComboBox
            v-model="requestLocation"
            :options="requestLocationOptions"
            :placeholder="
              t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_REQUEST_LOCATION.PLACEHOLDER')
            "
            class="[&>div>button]:bg-n-alpha-black2"
          />
          <ComboBox
            v-if="source === 'context'"
            v-model="contextPath"
            :options="props.contextFieldOptions"
            :placeholder="
              t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_CONTEXT_FIELD.PLACEHOLDER')
            "
            class="[&>div>button]:bg-n-alpha-black2"
          />
          <Input
            v-else-if="source === 'fixed'"
            v-model="fixedValue"
            :placeholder="fixedValuePlaceholder"
          />
        </div>
        <Input
          v-if="requestLocation !== 'template'"
          v-model="requestKey"
          :placeholder="
            t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_REQUEST_KEY.PLACEHOLDER', {
              name: name || 'parameter_name',
            })
          "
        />
        <Input
          v-model="description"
          :placeholder="
            t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_DESCRIPTION.PLACEHOLDER')
          "
        />
        <p v-if="source === 'context'" class="text-xs text-n-slate-10 -mt-1">
          {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_CONTEXT_FIELD.HELP_TEXT') }}
        </p>
        <label class="flex items-center gap-2 cursor-pointer">
          <Checkbox v-model="required" />
          <span class="text-sm text-n-slate-11">
            {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAM_REQUIRED.LABEL') }}
          </span>
        </label>
      </div>
      <Button
        solid
        slate
        icon="i-lucide-trash"
        class="flex-shrink-0"
        @click.stop="emit('remove')"
      />
    </div>
    <span
      v-if="showErrors && validationError"
      class="block mt-1 text-sm text-n-ruby-11"
    >
      {{ validationErrorMessage }}
    </span>
  </li>
</template>
