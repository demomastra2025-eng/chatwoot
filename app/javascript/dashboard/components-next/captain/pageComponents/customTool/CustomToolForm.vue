<script setup>
import {
  reactive,
  computed,
  ref,
  shallowRef,
  useTemplateRef,
  watch,
} from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import CaptainContextFieldsAPI from 'dashboard/api/captain/contextFields';
import ParamRow from './ParamRow.vue';
import AuthConfig from './AuthConfig.vue';
import ToolTestPanel from './ToolTestPanel.vue';

const props = defineProps({
  mode: {
    type: String,
    default: 'create',
    validator: value => ['create', 'edit', 'duplicate'].includes(value),
  },
  tool: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['submit', 'cancel']);

let cachedContextFieldOptions = null;
let contextFieldsRequest = null;

const { t } = useI18n();
const contextFieldOptions = shallowRef([]);
const hasLoadedContextFields = ref(false);
const isSyncingFormState = ref(false);

const formState = {
  uiFlags: useMapGetter('captainCustomTools/getUIFlags'),
};

const PARAM_UI_KEY = '__uiKey';
const API_KEY_LOCATIONS = ['header', 'query'];
let nextParamUiKey = 0;

const createInitialState = () => ({
  title: '',
  group_name: '',
  description: '',
  endpoint_url: '',
  http_method: 'GET',
  request_body_type: 'json',
  request_template: '',
  response_template: '',
  auth_type: 'none',
  auth_config: {},
  allow_file_artifacts: true,
  param_schema: [],
});

const state = reactive(createInitialState());

const DEFAULT_PARAM = {
  name: '',
  type: 'string',
  description: '',
  required: false,
  source: 'agent',
  context_path: '',
  fixed_value: '',
  request_location: 'template',
  request_key: '',
};

const buildParamUiKey = () => {
  const currentKey = nextParamUiKey;
  nextParamUiKey += 1;
  return `param-${currentKey}`;
};

const serializeFixedValue = value => {
  if (value === null || value === undefined) {
    return '';
  }

  if (typeof value === 'object') {
    return JSON.stringify(value);
  }

  return String(value);
};

const normalizeAuthConfig = (authType, authConfig = {}) => {
  const config =
    authConfig && typeof authConfig === 'object' ? { ...authConfig } : {};

  switch (authType) {
    case 'bearer':
      return {
        token: config.token || '',
      };
    case 'basic':
      return {
        username: config.username || '',
        password: config.password || '',
      };
    case 'api_key':
      return {
        name: config.name || '',
        key: config.key || '',
        location: API_KEY_LOCATIONS.includes(config.location)
          ? config.location
          : 'header',
      };
    default:
      return {};
  }
};

const createParamState = param => ({
  ...DEFAULT_PARAM,
  name: param?.name || '',
  type: param?.type || DEFAULT_PARAM.type,
  description: param?.description || '',
  required: Boolean(param?.required),
  source: param?.source || DEFAULT_PARAM.source,
  context_path: param?.context_path || '',
  fixed_value: serializeFixedValue(param?.fixed_value),
  request_location: param?.request_location || DEFAULT_PARAM.request_location,
  request_key: param?.request_key || '',
  [PARAM_UI_KEY]: param?.[PARAM_UI_KEY] || buildParamUiKey(),
});

const serializeParamForPayload = param => {
  const serializedParam = {
    name: param?.name || '',
    type: param?.type || DEFAULT_PARAM.type,
    description: param?.description || '',
    required: Boolean(param?.required),
    source: param?.source || DEFAULT_PARAM.source,
    request_location: param?.request_location || DEFAULT_PARAM.request_location,
  };

  if (serializedParam.source === 'context') {
    serializedParam.context_path = param?.context_path || '';
  }

  if (serializedParam.source === 'fixed') {
    serializedParam.fixed_value = serializeFixedValue(param?.fixed_value);
  }

  if (serializedParam.request_location !== 'template') {
    serializedParam.request_key =
      param?.request_key?.trim() || serializedParam.name;
  }

  return serializedParam;
};

const isStructurallyValidEndpointUrl = value => {
  if (!value) {
    return true;
  }

  try {
    const sanitizedValue = value.replace(/\{\{[^}]+\}\}/g, 'placeholder');
    const parsedUrl = new URL(sanitizedValue);
    const host = parsedUrl.hostname || '';

    if (parsedUrl.protocol !== 'https:') {
      return false;
    }

    if (
      !host ||
      host.toLowerCase() === 'localhost' ||
      host.endsWith('.local')
    ) {
      return false;
    }

    if (/^\d+\.\d+\.\d+\.\d+$/.test(host) || host.includes(':')) {
      return false;
    }

    if (Array.from(host).some(char => char.charCodeAt(0) > 127)) {
      return false;
    }

    return true;
  } catch {
    return false;
  }
};

const syncFormState = updater => {
  isSyncingFormState.value = true;
  try {
    updater();
  } finally {
    isSyncingFormState.value = false;
  }
};

const resetState = () => {
  syncFormState(() => {
    Object.assign(state, createInitialState());
  });
};

const applyToolState = tool => {
  syncFormState(() => {
    Object.assign(state, {
      ...createInitialState(),
      title: tool.title || '',
      group_name: tool.group_name || '',
      description: tool.description || '',
      endpoint_url: tool.endpoint_url || '',
      http_method: tool.http_method || 'GET',
      request_body_type: tool.request_body_type || 'json',
      request_template: tool.request_template || '',
      response_template: tool.response_template || '',
      auth_type: tool.auth_type || 'none',
      auth_config: normalizeAuthConfig(
        tool.auth_type || 'none',
        tool.auth_config
      ),
      allow_file_artifacts: tool.allow_file_artifacts !== false,
      param_schema: (tool.param_schema || []).map(createParamState),
    });
  });
};

watch(
  () => [props.mode, props.tool],
  ([mode, tool]) => {
    if (['edit', 'duplicate'].includes(mode) && tool?.id) {
      applyToolState(tool);
      if (mode === 'duplicate') {
        state.title = t('CAPTAIN.CUSTOM_TOOLS.DUPLICATE.TITLE_COPY', {
          title: tool.title,
        });
      }
      return;
    }

    resetState();
  },
  { immediate: true }
);

watch(
  () => state.auth_type,
  (authType, previousAuthType) => {
    if (isSyncingFormState.value || authType === previousAuthType) {
      return;
    }

    state.auth_config = normalizeAuthConfig(authType);
  },
  { flush: 'sync' }
);

const validationRules = {
  title: { required },
  endpoint_url: {
    required,
    isStructurallyValidEndpointUrl,
  },
  http_method: { required },
  auth_type: { required },
};

const httpMethodOptions = computed(() =>
  ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'].map(method => ({
    value: method,
    label: method,
  }))
);

const showRequestTemplate = computed(
  () => !['GET', 'HEAD'].includes(state.http_method)
);

const requestBodyTypeOptions = computed(() => [
  {
    value: 'json',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.REQUEST_BODY_TYPES.JSON'),
  },
  {
    value: 'form_urlencoded',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.REQUEST_BODY_TYPES.FORM_URLENCODED'),
  },
]);

const requestBodyHelpText = computed(() => {
  if (state.request_body_type === 'form_urlencoded') {
    return t(
      'CAPTAIN.CUSTOM_TOOLS.FORM.REQUEST_TEMPLATE.FORM_URLENCODED_HELP_TEXT'
    );
  }

  return t('CAPTAIN.CUSTOM_TOOLS.FORM.REQUEST_TEMPLATE.HELP_TEXT');
});

const responseTemplatePlaceholder = computed(() => '{{ response.some_field }}');

const authTypeOptions = computed(() => [
  { value: 'none', label: t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_TYPES.NONE') },
  { value: 'bearer', label: t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_TYPES.BEARER') },
  { value: 'basic', label: t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_TYPES.BASIC') },
  {
    value: 'api_key',
    label: t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_TYPES.API_KEY'),
  },
]);

const toContextFieldOptions = fields =>
  fields
    .slice()
    .sort((leftField, rightField) => {
      const groupComparison = (leftField.group_name || '').localeCompare(
        rightField.group_name || ''
      );
      if (groupComparison !== 0) {
        return groupComparison;
      }

      return leftField.title.localeCompare(rightField.title);
    })
    .map(field => ({
      value: field.id,
      label: field.group_name
        ? `${field.group_name} - ${field.title}`
        : field.title,
    }));

const v$ = useVuelidate(validationRules, state);

const isLoading = computed(() =>
  props.mode === 'edit'
    ? formState.uiFlags.value.updatingItem
    : formState.uiFlags.value.creatingItem
);

const fieldErrorMessages = computed(() => ({
  TITLE: t('CAPTAIN.CUSTOM_TOOLS.FORM.TITLE.ERROR'),
  ENDPOINT_URL: t('CAPTAIN.CUSTOM_TOOLS.FORM.ENDPOINT_URL.ERROR'),
}));

const authConfigErrorMessages = computed(() => ({
  BEARER_TOKEN: t(
    'CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.AUTH_BEARER_TOKEN_REQUIRED'
  ),
  BASIC_USERNAME: t(
    'CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.AUTH_BASIC_USERNAME_REQUIRED'
  ),
  BASIC_PASSWORD: t(
    'CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.AUTH_BASIC_PASSWORD_REQUIRED'
  ),
  API_KEY_NAME: t(
    'CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.AUTH_API_KEY_NAME_REQUIRED'
  ),
  API_KEY_VALUE: t(
    'CAPTAIN.CUSTOM_TOOLS.FORM.ERRORS.AUTH_API_KEY_VALUE_REQUIRED'
  ),
}));

const showAuthConfigErrors = ref(false);

const submitLabel = computed(() =>
  props.mode === 'edit' ? t('CAPTAIN.FORM.EDIT') : t('CAPTAIN.FORM.CREATE')
);

const getErrorMessage = (field, errorKey) => {
  return v$.value[field].$error ? fieldErrorMessages.value[errorKey] : '';
};

const formErrors = computed(() => ({
  title: getErrorMessage('title', 'TITLE'),
  endpoint_url: getErrorMessage('endpoint_url', 'ENDPOINT_URL'),
}));

const authConfigErrors = computed(() => {
  const normalizedAuthConfig = normalizeAuthConfig(
    state.auth_type,
    state.auth_config
  );

  switch (state.auth_type) {
    case 'bearer':
      return {
        token: normalizedAuthConfig.token?.trim()
          ? ''
          : authConfigErrorMessages.value.BEARER_TOKEN,
      };
    case 'basic':
      return {
        username: normalizedAuthConfig.username?.trim()
          ? ''
          : authConfigErrorMessages.value.BASIC_USERNAME,
        password: normalizedAuthConfig.password?.trim()
          ? ''
          : authConfigErrorMessages.value.BASIC_PASSWORD,
      };
    case 'api_key':
      return {
        name: normalizedAuthConfig.name?.trim()
          ? ''
          : authConfigErrorMessages.value.API_KEY_NAME,
        key: normalizedAuthConfig.key?.trim()
          ? ''
          : authConfigErrorMessages.value.API_KEY_VALUE,
      };
    default:
      return {};
  }
});

const visibleAuthConfigErrors = computed(() =>
  showAuthConfigErrors.value ? authConfigErrors.value : {}
);

const paramsRef = useTemplateRef('paramsRef');
const toolTestPanelRef = useTemplateRef('toolTestPanelRef');
const isAutoTesting = ref(false);

const isParamsValid = () => {
  if (!paramsRef.value || paramsRef.value.length === 0) {
    return true;
  }
  return paramsRef.value.every(param => param.validate());
};

const isAuthConfigValid = () =>
  Object.values(authConfigErrors.value).every(errorMessage => !errorMessage);

const toolDraftForTesting = computed(() => ({
  title: state.title,
  group_name: state.group_name,
  description: state.description,
  endpoint_url: state.endpoint_url,
  http_method: state.http_method,
  request_body_type: state.request_body_type,
  request_template: showRequestTemplate.value ? state.request_template : '',
  response_template: state.response_template,
  auth_type: state.auth_type,
  auth_config: normalizeAuthConfig(state.auth_type, state.auth_config),
  allow_file_artifacts: state.allow_file_artifacts,
  param_schema: state.param_schema.map(serializeParamForPayload),
}));

const removeParam = index => {
  state.param_schema.splice(index, 1);
};

const addParam = () => {
  state.param_schema.push(createParamState());
};

const loadContextFields = async () => {
  if (hasLoadedContextFields.value) {
    return;
  }

  if (cachedContextFieldOptions !== null) {
    contextFieldOptions.value = cachedContextFieldOptions;
    hasLoadedContextFields.value = true;
    return;
  }

  if (!contextFieldsRequest) {
    contextFieldsRequest = CaptainContextFieldsAPI.get()
      .then(response => toContextFieldOptions(response.data || []))
      .then(options => {
        cachedContextFieldOptions = options;
        return options;
      })
      .finally(() => {
        contextFieldsRequest = null;
      });
  }

  try {
    contextFieldOptions.value = await contextFieldsRequest;
  } catch {
    contextFieldOptions.value = [];
  } finally {
    hasLoadedContextFields.value = true;
  }
};

const needsContextFields = computed(() =>
  state.param_schema.some(param => param.source === 'context')
);

watch(
  needsContextFields,
  shouldLoadContextFields => {
    if (shouldLoadContextFields) {
      loadContextFields();
    }
  },
  { immediate: true }
);

const handleCancel = () => emit('cancel');

watch(
  () => [state.auth_type, state.auth_config],
  () => {
    showAuthConfigErrors.value = false;
  },
  { deep: true }
);

const validateBeforeToolTest = async () => {
  const isFormValid = await v$.value.$validate();
  showAuthConfigErrors.value = true;
  return isFormValid && isAuthConfigValid() && isParamsValid();
};

const handleSubmit = async () => {
  if (!(await validateBeforeToolTest())) {
    return;
  }

  if (props.mode !== 'edit') {
    isAutoTesting.value = true;
    let testResult;
    try {
      testResult = await toolTestPanelRef.value?.runTestForCreate();
    } finally {
      isAutoTesting.value = false;
    }

    if (!testResult?.response?.successful) {
      if (testResult) {
        useAlert(
          t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.TEST.REQUIRED_SUCCESS')
        );
      }
      return;
    }
  }

  emit('submit', {
    ...state,
    auth_config: normalizeAuthConfig(state.auth_type, state.auth_config),
    request_body_type: state.request_body_type,
    request_template: showRequestTemplate.value ? state.request_template : '',
    param_schema: state.param_schema.map(serializeParamForPayload),
  });
};
</script>

<template>
  <form
    class="flex flex-col px-4 -mx-4 gap-4 max-h-[calc(100vh-200px)] overflow-y-scroll"
    @submit.prevent="handleSubmit"
  >
    <Input
      v-model="state.title"
      :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.TITLE.LABEL')"
      :placeholder="t('CAPTAIN.CUSTOM_TOOLS.FORM.TITLE.PLACEHOLDER')"
      :message="formErrors.title"
      :message-type="formErrors.title ? 'error' : 'info'"
    />

    <Input
      v-model="state.group_name"
      :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.GROUP_NAME.LABEL')"
      :placeholder="t('CAPTAIN.CUSTOM_TOOLS.FORM.GROUP_NAME.PLACEHOLDER')"
    />

    <TextArea
      v-model="state.description"
      :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.DESCRIPTION.LABEL')"
      :placeholder="t('CAPTAIN.CUSTOM_TOOLS.FORM.DESCRIPTION.PLACEHOLDER')"
      :rows="2"
    />

    <div class="flex gap-2">
      <div class="flex flex-col gap-1 w-28">
        <label class="mb-0.5 text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_METHOD.LABEL') }}
        </label>
        <ComboBox
          v-model="state.http_method"
          :options="httpMethodOptions"
          class="[&>div>button]:bg-n-alpha-black2 [&_li]:font-mono [&_button]:font-mono [&>div>button]:outline-offset-[-1px]"
        />
      </div>
      <Input
        v-model="state.endpoint_url"
        :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.ENDPOINT_URL.LABEL')"
        :placeholder="t('CAPTAIN.CUSTOM_TOOLS.FORM.ENDPOINT_URL.PLACEHOLDER')"
        :message="formErrors.endpoint_url"
        :message-type="formErrors.endpoint_url ? 'error' : 'info'"
        class="flex-1"
      />
    </div>
    <p class="text-xs text-n-slate-11 -mt-2">
      {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.ENDPOINT_URL.HELP_TEXT') }}
    </p>

    <div class="flex flex-col gap-1">
      <label class="mb-0.5 text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.AUTH_TYPE.LABEL') }}
      </label>
      <ComboBox
        v-model="state.auth_type"
        :options="authTypeOptions"
        class="[&>div>button]:bg-n-alpha-black2"
      />
    </div>

    <AuthConfig
      v-model:auth-config="state.auth_config"
      :auth-type="state.auth_type"
      :errors="visibleAuthConfigErrors"
    />

    <div class="flex flex-col gap-2">
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAMETERS.LABEL') }}
      </label>
      <p class="text-xs text-n-slate-11 -mt-1">
        {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.PARAMETERS.HELP_TEXT') }}
      </p>
      <ul v-if="state.param_schema.length > 0" class="grid gap-2 list-none">
        <ParamRow
          v-for="(param, index) in state.param_schema"
          :key="param[PARAM_UI_KEY]"
          ref="paramsRef"
          v-model:name="param.name"
          v-model:type="param.type"
          v-model:description="param.description"
          v-model:required="param.required"
          v-model:source="param.source"
          v-model:context-path="param.context_path"
          v-model:fixed-value="param.fixed_value"
          v-model:request-location="param.request_location"
          v-model:request-key="param.request_key"
          :all-param-names="state.param_schema.map(item => item.name)"
          :context-field-options="contextFieldOptions"
          @remove="removeParam(index)"
        />
      </ul>
      <Button
        type="button"
        sm
        ghost
        blue
        icon="i-lucide-plus"
        :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.ADD_PARAMETER')"
        @click="addParam"
      />
    </div>

    <div v-if="showRequestTemplate" class="flex flex-col gap-1">
      <label class="mb-0.5 text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.REQUEST_BODY_TYPE.LABEL') }}
      </label>
      <ComboBox
        v-model="state.request_body_type"
        :options="requestBodyTypeOptions"
        class="[&>div>button]:bg-n-alpha-black2"
      />
    </div>

    <TextArea
      v-if="showRequestTemplate"
      v-model="state.request_template"
      :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.REQUEST_TEMPLATE.LABEL')"
      :placeholder="t('CAPTAIN.CUSTOM_TOOLS.FORM.REQUEST_TEMPLATE.PLACEHOLDER')"
      :rows="4"
      class="[&_textarea]:font-mono"
    />
    <p v-if="showRequestTemplate" class="text-xs text-n-slate-11 -mt-2">
      {{ requestBodyHelpText }}
    </p>

    <TextArea
      v-model="state.response_template"
      :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.RESPONSE_TEMPLATE.LABEL')"
      :placeholder="responseTemplatePlaceholder"
      :rows="4"
      class="[&_textarea]:font-mono"
    />
    <p class="text-xs text-n-slate-11 -mt-2">
      {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.RESPONSE_TEMPLATE.HELP_TEXT') }}
    </p>

    <label
      class="flex gap-3 p-3 rounded-lg border border-n-weak bg-n-alpha-1 cursor-pointer"
    >
      <Checkbox v-model="state.allow_file_artifacts" class="mt-0.5 shrink-0" />
      <span class="flex flex-col gap-1">
        <span class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.ALLOW_FILE_ARTIFACTS.LABEL') }}
        </span>
        <span class="text-xs text-n-slate-11">
          {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.ALLOW_FILE_ARTIFACTS.HELP_TEXT') }}
        </span>
      </span>
    </label>

    <ToolTestPanel
      ref="toolTestPanelRef"
      :custom-tool="toolDraftForTesting"
      :disabled="isLoading || isAutoTesting"
      :validate-before-run="validateBeforeToolTest"
    />

    <div class="flex gap-3 justify-between items-center w-full">
      <Button
        type="button"
        variant="faded"
        color="slate"
        :label="t('CAPTAIN.FORM.CANCEL')"
        class="w-full bg-n-alpha-2 text-n-blue-11 hover:bg-n-alpha-3"
        @click="handleCancel"
      />
      <Button
        type="submit"
        :label="submitLabel"
        class="w-full"
        :is-loading="isLoading || isAutoTesting"
        :disabled="isLoading || isAutoTesting"
      />
    </div>
  </form>
</template>
