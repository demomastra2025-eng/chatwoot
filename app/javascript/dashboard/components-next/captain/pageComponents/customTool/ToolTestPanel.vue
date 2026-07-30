<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  customTool: {
    type: Object,
    required: true,
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  validateBeforeRun: {
    type: Function,
    default: null,
  },
});

const { t } = useI18n();
const store = useStore();
const formState = {
  uiFlags: useMapGetter('captainCustomTools/getUIFlags'),
};

const state = reactive({
  agentValues: {},
  contextValues: {},
  preview: null,
  response: null,
});
const showSampleErrors = ref(false);
const lastSuccessfulTestFingerprint = ref('');
const confirmDialog = ref(null);

const agentParamDefinitions = computed(() =>
  (props.customTool.param_schema || []).filter(
    param => param.source === 'agent' && param.name?.trim()
  )
);

const contextParamDefinitions = computed(() =>
  (props.customTool.param_schema || []).filter(
    param => param.source === 'context' && param.context_path
  )
);

const fixedParamDefinitions = computed(() =>
  (props.customTool.param_schema || []).filter(
    param => param.source === 'fixed' && param.name?.trim()
  )
);

const isPreviewing = computed(() => formState.uiFlags.value.previewingTool);
const isTesting = computed(() => formState.uiFlags.value.testingTool);
const isBusy = computed(
  () => props.disabled || isPreviewing.value || isTesting.value
);

const sampleInputErrorMessages = computed(() => ({
  REQUIRED: t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.INPUT.ERRORS.REQUIRED'),
  INVALID_NUMBER: t(
    'CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.INPUT.ERRORS.INVALID_NUMBER'
  ),
  INVALID_BOOLEAN: t(
    'CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.INPUT.ERRORS.INVALID_BOOLEAN'
  ),
  INVALID_ARRAY: t(
    'CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.INPUT.ERRORS.INVALID_ARRAY'
  ),
  INVALID_OBJECT: t(
    'CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.INPUT.ERRORS.INVALID_OBJECT'
  ),
}));

function formatBlockValue(value) {
  if (value === null || value === undefined || value === '') {
    return '';
  }

  if (typeof value === 'string') {
    try {
      return JSON.stringify(JSON.parse(value), null, 2);
    } catch {
      return value;
    }
  }

  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

const syncValueMap = (target, keys) => {
  const nextKeys = new Set(keys);

  Object.keys(target).forEach(key => {
    if (!nextKeys.has(key)) {
      delete target[key];
    }
  });

  keys.forEach(key => {
    if (!(key in target)) {
      target[key] = '';
    }
  });
};

watch(
  [agentParamDefinitions, contextParamDefinitions],
  ([nextAgentParams, nextContextParams]) => {
    showSampleErrors.value = false;
    syncValueMap(
      state.agentValues,
      nextAgentParams.map(param => param.name.trim())
    );
    syncValueMap(
      state.contextValues,
      nextContextParams.map(param => param.context_path)
    );
  },
  { immediate: true }
);

watch(
  () => [state.agentValues, state.contextValues],
  () => {
    showSampleErrors.value = false;
  },
  { deep: true }
);

watch(
  () => ({
    endpointUrl: props.customTool.endpoint_url,
    httpMethod: props.customTool.http_method,
    requestTemplate: props.customTool.request_template,
    responseTemplate: props.customTool.response_template,
    authType: props.customTool.auth_type,
    authConfig: props.customTool.auth_config,
    httpOptions: props.customTool.http_options,
    allowFileArtifacts: props.customTool.allow_file_artifacts,
    paramSchema: props.customTool.param_schema,
    agentValues: state.agentValues,
    contextValues: state.contextValues,
  }),
  () => {
    state.preview = null;
    state.response = null;
    lastSuccessfulTestFingerprint.value = '';
  },
  { deep: true }
);

const hasAnySampleInputs = computed(
  () =>
    agentParamDefinitions.value.length > 0 ||
    contextParamDefinitions.value.length > 0
);

const responseStatusLabel = computed(() => {
  if (!state.response) {
    return '';
  }

  return state.response.successful
    ? t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.RESPONSE.SUCCESS_STATUS', {
        status: state.response.status,
      })
    : t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.RESPONSE.ERROR_STATUS', {
        status: state.response.status,
      });
});

const responseStatusClasses = computed(() =>
  state.response?.successful
    ? 'bg-n-teal-9/10 text-n-teal-11'
    : 'bg-n-ruby-9/10 text-n-ruby-11'
);

const requestPreviewBody = computed(() => {
  if (!state.preview) {
    return '';
  }

  if (!state.preview.body) {
    return ['GET', 'HEAD'].includes(props.customTool.http_method)
      ? t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.PREVIEW.NO_BODY_FOR_METHOD')
      : t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.PREVIEW.NO_BODY_TEMPLATE');
  }

  return formatBlockValue(state.preview.body);
});

const previewUrl = computed(() => {
  const url = state.preview?.url;
  if (!url) {
    return '';
  }

  if (
    props.customTool.auth_type !== 'api_key' ||
    props.customTool.auth_config?.location !== 'query' ||
    !props.customTool.auth_config?.name
  ) {
    return url;
  }

  try {
    const previewUrlObject = new URL(url);
    previewUrlObject.searchParams.set(
      props.customTool.auth_config.name,
      '••••••'
    );
    return previewUrlObject.toString();
  } catch {
    return url;
  }
});

const resolvedParamsPreview = computed(() =>
  state.preview?.resolved_params
    ? formatBlockValue(state.preview.resolved_params)
    : ''
);

const requestHeadersPreview = computed(() =>
  state.preview?.headers ? formatBlockValue(state.preview.headers) : ''
);

const rawResponseBody = computed(() =>
  state.response ? formatBlockValue(state.response.body) : ''
);

const formattedResponseBody = computed(() =>
  state.response ? formatBlockValue(state.response.formatted_body) : ''
);

const hasFormattedResponseBody = computed(
  () =>
    !!state.response &&
    state.response.formatted_body !== undefined &&
    state.response.formatted_body !== null
);

const responseFormatError = computed(() => state.response?.format_error || '');

const showFormattedResponse = computed(
  () =>
    hasFormattedResponseBody.value &&
    (props.customTool.response_template?.trim() ||
      state.response.formatted_body !== state.response.body)
);

const testPanelTooltip = computed(() =>
  [
    t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.DESCRIPTION'),
    t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.ENCODING_HINT'),
  ]
    .filter(Boolean)
    .join('\n\n')
);

const fixedValueSummary = value => {
  if (value === null || value === undefined || value === '') {
    return '""';
  }

  if (typeof value === 'string') {
    return value;
  }

  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
};

const inputPlaceholder = param => {
  if (['array', 'object'].includes(param.type)) {
    return t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.INPUT.JSON_PLACEHOLDER');
  }

  if (param.type === 'boolean') {
    return t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.INPUT.BOOLEAN_PLACEHOLDER');
  }

  if (param.type === 'number') {
    return t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.INPUT.NUMBER_PLACEHOLDER');
  }

  return t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.INPUT.TEXT_PLACEHOLDER');
};

const parseStructuredSampleValue = value => {
  if (value === null || value === undefined || value === '') {
    return null;
  }

  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
};

const sampleInputErrorFor = (param, value) => {
  const normalizedValue =
    typeof value === 'string' ? value.trim() : String(value ?? '').trim();

  if (param.required && normalizedValue === '') {
    return sampleInputErrorMessages.value.REQUIRED;
  }

  if (normalizedValue === '') {
    return '';
  }

  if (param.type === 'number' && Number.isNaN(Number(normalizedValue))) {
    return sampleInputErrorMessages.value.INVALID_NUMBER;
  }

  if (
    param.type === 'boolean' &&
    !['true', 'false'].includes(normalizedValue.toLowerCase())
  ) {
    return sampleInputErrorMessages.value.INVALID_BOOLEAN;
  }

  if (!['array', 'object'].includes(param.type)) {
    return '';
  }

  const parsedValue = parseStructuredSampleValue(normalizedValue);
  if (parsedValue === null) {
    return param.type === 'array'
      ? sampleInputErrorMessages.value.INVALID_ARRAY
      : sampleInputErrorMessages.value.INVALID_OBJECT;
  }

  if (param.type === 'array' && !Array.isArray(parsedValue)) {
    return sampleInputErrorMessages.value.INVALID_ARRAY;
  }

  if (
    param.type === 'object' &&
    (typeof parsedValue !== 'object' ||
      Array.isArray(parsedValue) ||
      parsedValue === null)
  ) {
    return sampleInputErrorMessages.value.INVALID_OBJECT;
  }

  return '';
};

const agentSampleErrors = computed(() =>
  Object.fromEntries(
    agentParamDefinitions.value.map(param => [
      param.name,
      sampleInputErrorFor(param, state.agentValues[param.name]),
    ])
  )
);

const contextSampleErrors = computed(() =>
  Object.fromEntries(
    contextParamDefinitions.value.map(param => [
      param.context_path,
      sampleInputErrorFor(param, state.contextValues[param.context_path]),
    ])
  )
);

const visibleAgentSampleErrors = computed(() =>
  showSampleErrors.value ? agentSampleErrors.value : {}
);

const visibleContextSampleErrors = computed(() =>
  showSampleErrors.value ? contextSampleErrors.value : {}
);

const validateSampleInputs = () => {
  showSampleErrors.value = true;

  return [
    ...Object.values(agentSampleErrors.value),
    ...Object.values(contextSampleErrors.value),
  ].every(errorMessage => !errorMessage);
};

const buildRequestPayload = () => ({
  customTool: {
    title: props.customTool.title,
    group_name: props.customTool.group_name,
    description: props.customTool.description,
    endpoint_url: props.customTool.endpoint_url,
    http_method: props.customTool.http_method,
    request_body_type: props.customTool.request_body_type || 'json',
    request_template: props.customTool.request_template,
    response_template: props.customTool.response_template,
    auth_type: props.customTool.auth_type,
    auth_config: props.customTool.auth_config || {},
    http_options: props.customTool.http_options || {},
    allow_file_artifacts: props.customTool.allow_file_artifacts !== false,
    param_schema: props.customTool.param_schema || [],
  },
  testPayload: {
    agent_params: { ...state.agentValues },
    context_values: { ...state.contextValues },
  },
});

const isMutatingRequest = computed(
  () => !['GET', 'HEAD'].includes(props.customTool.http_method)
);

const logicalRequestCount = () => {
  const batching = props.customTool.http_options?.batching;
  if (!batching?.enabled) {
    return 1;
  }

  const sampleItems = parseStructuredSampleValue(
    state.agentValues[batching.items_parameter]
  );
  const batchSize = Number(batching.batch_size);
  if (
    !Array.isArray(sampleItems) ||
    !Number.isInteger(batchSize) ||
    batchSize < 1
  ) {
    return 1;
  }

  return Math.max(1, Math.ceil(sampleItems.length / batchSize));
};

const requestRiskDetails = computed(() => {
  const retry = props.customTool.http_options?.retry;
  const redirects = props.customTool.http_options?.redirects;
  const attempts = retry?.enabled ? Number(retry.max_attempts) || 1 : 1;
  const redirectHops = redirects?.enabled
    ? (Number(redirects.max_redirects) || 0) + 1
    : 1;
  const logicalRequests = logicalRequestCount();

  return {
    logicalRequests,
    attempts,
    redirectHops,
    requests: Math.min(25, logicalRequests * attempts * redirectHops),
  };
});

const confirmMutatingMultiRequest = async () => {
  if (!isMutatingRequest.value || requestRiskDetails.value.requests <= 1) {
    return true;
  }

  return Boolean(await confirmDialog.value?.showConfirmation());
};

const ensureRunnable = async () => {
  const isFormValid = props.validateBeforeRun
    ? await props.validateBeforeRun()
    : true;

  const areSampleInputsValid = validateSampleInputs();

  if (isFormValid && areSampleInputsValid) {
    return true;
  }

  useAlert(
    isFormValid
      ? t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.INPUT.ERRORS.FIX_ERRORS')
      : t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.VALIDATION_ERROR')
  );
  return false;
};

const handlePreview = async () => {
  if (!(await ensureRunnable())) {
    return;
  }

  try {
    const result = await store.dispatch(
      'captainCustomTools/previewTool',
      buildRequestPayload()
    );
    state.preview = result.preview || null;
    state.response = null;
  } catch (error) {
    useAlert(
      error?.message ||
        t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.PREVIEW.ERROR_MESSAGE')
    );
  }
};

const executeTest = async ({ reuseSuccessfulResult = false } = {}) => {
  if (!(await ensureRunnable())) {
    return null;
  }

  const requestPayload = buildRequestPayload();
  const requestFingerprint = JSON.stringify(requestPayload);
  if (
    reuseSuccessfulResult &&
    state.response?.successful &&
    lastSuccessfulTestFingerprint.value === requestFingerprint
  ) {
    return { preview: state.preview, response: state.response };
  }

  if (!(await confirmMutatingMultiRequest())) {
    return null;
  }

  try {
    const result = await store.dispatch(
      'captainCustomTools/testTool',
      requestPayload
    );
    state.preview = result.preview || null;
    state.response = result.response || null;
    lastSuccessfulTestFingerprint.value = result.response?.successful
      ? requestFingerprint
      : '';
    return result;
  } catch (error) {
    lastSuccessfulTestFingerprint.value = '';
    useAlert(
      error?.message ||
        t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.TEST.ERROR_MESSAGE')
    );
    return null;
  }
};

const handleTest = () => executeTest();
const runTestForCreate = () =>
  executeTest({
    reuseSuccessfulResult: true,
  });

defineExpose({ runTestForCreate });
</script>

<template>
  <woot-confirm-modal
    ref="confirmDialog"
    :title="t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.TEST.CONFIRM_TITLE')"
    :description="
      t(
        'CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.TEST.CONFIRM_DESCRIPTION',
        requestRiskDetails
      )
    "
    :confirm-label="
      t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.TEST.CONFIRM_ACTION')
    "
  />
  <section
    class="flex flex-col gap-3 p-4 rounded-xl border border-n-weak bg-n-alpha-2"
  >
    <div class="flex items-center gap-2">
      <h3 class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.TITLE') }}
      </h3>
      <i
        v-tooltip.top="testPanelTooltip"
        class="i-lucide-info h-4 w-4 cursor-help text-n-slate-10"
      />
    </div>

    <div v-if="fixedParamDefinitions.length" class="flex flex-col gap-2">
      <p class="text-xs font-medium uppercase tracking-wide text-n-slate-10">
        {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.FIXED_PARAMS_LABEL') }}
      </p>
      <div class="flex flex-wrap gap-2">
        <span
          v-for="param in fixedParamDefinitions"
          :key="`fixed-${param.name}`"
          class="px-2 py-1 text-xs rounded-md bg-n-alpha-black2 text-n-slate-11 font-mono"
        >
          {{ `${param.name}=${fixedValueSummary(param.fixed_value)}` }}
        </span>
      </div>
    </div>

    <div v-if="agentParamDefinitions.length" class="flex flex-col gap-2">
      <p class="text-xs font-medium uppercase tracking-wide text-n-slate-10">
        {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.AGENT_PARAMS_LABEL') }}
      </p>
      <div class="grid gap-3 md:grid-cols-2">
        <div
          v-for="param in agentParamDefinitions"
          :key="`agent-${param.name}`"
          class="p-3 rounded-lg border border-n-weak bg-n-solid-1"
        >
          <TextArea
            v-if="['array', 'object'].includes(param.type)"
            v-model="state.agentValues[param.name]"
            :label="param.name"
            :placeholder="inputPlaceholder(param)"
            :rows="3"
            :message="visibleAgentSampleErrors[param.name]"
            :message-type="
              visibleAgentSampleErrors[param.name] ? 'error' : 'info'
            "
            class="[&_textarea]:font-mono"
          />
          <Input
            v-else
            v-model="state.agentValues[param.name]"
            :label="param.name"
            :placeholder="inputPlaceholder(param)"
            :message="visibleAgentSampleErrors[param.name]"
            :message-type="
              visibleAgentSampleErrors[param.name] ? 'error' : 'info'
            "
            class="[&_input]:font-mono"
          />
          <p class="mt-1 text-xs text-n-slate-10">
            {{ param.description }}
          </p>
        </div>
      </div>
    </div>

    <div v-if="contextParamDefinitions.length" class="flex flex-col gap-2">
      <p class="text-xs font-medium uppercase tracking-wide text-n-slate-10">
        {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.CONTEXT_PARAMS_LABEL') }}
      </p>
      <div class="grid gap-3 md:grid-cols-2">
        <div
          v-for="param in contextParamDefinitions"
          :key="`context-${param.name}-${param.context_path}`"
          class="p-3 rounded-lg border border-n-weak bg-n-solid-1"
        >
          <TextArea
            v-if="['array', 'object'].includes(param.type)"
            v-model="state.contextValues[param.context_path]"
            :label="param.name"
            :placeholder="inputPlaceholder(param)"
            :rows="3"
            :message="visibleContextSampleErrors[param.context_path]"
            :message-type="
              visibleContextSampleErrors[param.context_path] ? 'error' : 'info'
            "
            class="[&_textarea]:font-mono"
          />
          <Input
            v-else
            v-model="state.contextValues[param.context_path]"
            :label="param.name"
            :placeholder="inputPlaceholder(param)"
            :message="visibleContextSampleErrors[param.context_path]"
            :message-type="
              visibleContextSampleErrors[param.context_path] ? 'error' : 'info'
            "
            class="[&_input]:font-mono"
          />
          <p class="mt-1 text-xs text-n-slate-10">
            {{
              t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.CONTEXT_FIELD_HINT', {
                field: param.context_path,
              })
            }}
          </p>
          <p class="mt-1 text-xs text-n-slate-10">
            {{ param.description }}
          </p>
        </div>
      </div>
    </div>

    <p v-if="!hasAnySampleInputs" class="text-xs text-n-slate-10">
      {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.NO_SAMPLES_REQUIRED') }}
    </p>

    <div class="flex flex-col gap-2 sm:flex-row">
      <Button
        type="button"
        sm
        ghost
        blue
        icon="i-lucide-eye"
        :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.PREVIEW.ACTION')"
        :is-loading="isPreviewing"
        :disabled="isBusy"
        @click="handlePreview"
      />
      <Button
        type="button"
        sm
        variant="faded"
        color="blue"
        icon="i-lucide-play"
        :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.TEST.ACTION')"
        :is-loading="isTesting"
        :disabled="isBusy"
        @click="handleTest"
      />
    </div>

    <div
      v-if="state.preview"
      class="flex flex-col gap-3 p-3 rounded-lg border border-n-weak bg-n-solid-1"
    >
      <div class="flex items-center justify-between gap-3">
        <p class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.PREVIEW.RESULT_TITLE') }}
        </p>
        <span
          v-if="state.response"
          class="px-2 py-1 text-xs font-medium rounded-md"
          :class="responseStatusClasses"
        >
          {{ responseStatusLabel }}
        </span>
      </div>

      <div class="flex flex-col gap-1">
        <p class="text-xs font-medium uppercase tracking-wide text-n-slate-10">
          {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.PREVIEW.URL_LABEL') }}
        </p>
        <pre
          class="p-3 overflow-x-auto text-xs rounded-lg bg-n-alpha-black2 text-n-slate-12 whitespace-pre-wrap break-all"
        ><code>{{ previewUrl }}</code></pre>
      </div>

      <div class="flex flex-col gap-1">
        <p class="text-xs font-medium uppercase tracking-wide text-n-slate-10">
          {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.PREVIEW.BODY_LABEL') }}
        </p>
        <pre
          class="p-3 overflow-x-auto text-xs rounded-lg bg-n-alpha-black2 text-n-slate-12 whitespace-pre-wrap break-all"
        ><code>{{ requestPreviewBody }}</code></pre>
      </div>

      <div v-if="requestHeadersPreview" class="flex flex-col gap-1">
        <p class="text-xs font-medium uppercase tracking-wide text-n-slate-10">
          {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.PREVIEW.HEADERS_LABEL') }}
        </p>
        <pre
          class="p-3 overflow-x-auto text-xs rounded-lg bg-n-alpha-black2 text-n-slate-12 whitespace-pre-wrap break-all"
        ><code>{{ requestHeadersPreview }}</code></pre>
      </div>

      <div class="flex flex-col gap-1">
        <p class="text-xs font-medium uppercase tracking-wide text-n-slate-10">
          {{
            t(
              'CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.PREVIEW.RESOLVED_PARAMS_LABEL'
            )
          }}
        </p>
        <pre
          class="p-3 overflow-x-auto text-xs rounded-lg bg-n-alpha-black2 text-n-slate-12 whitespace-pre-wrap break-all"
        ><code>{{ resolvedParamsPreview }}</code></pre>
      </div>

      <div v-if="state.response" class="flex flex-col gap-3">
        <div class="flex flex-col gap-1">
          <p
            class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
          >
            {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.RESPONSE.RAW_LABEL') }}
          </p>
          <pre
            class="p-3 overflow-x-auto text-xs rounded-lg bg-n-alpha-black2 text-n-slate-12 whitespace-pre-wrap break-all"
          ><code>{{ rawResponseBody }}</code></pre>
        </div>

        <div v-if="responseFormatError" class="flex flex-col gap-1">
          <p class="text-xs font-medium uppercase tracking-wide text-n-ruby-11">
            {{
              t(
                'CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.RESPONSE.FORMAT_ERROR_LABEL'
              )
            }}
          </p>
          <pre
            class="p-3 overflow-x-auto text-xs rounded-lg bg-n-ruby-3/40 text-n-ruby-11 whitespace-pre-wrap break-all"
          ><code>{{ responseFormatError }}</code></pre>
        </div>

        <div v-if="showFormattedResponse" class="flex flex-col gap-1">
          <p
            class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
          >
            {{
              t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.RESPONSE.FORMATTED_LABEL')
            }}
          </p>
          <pre
            class="p-3 overflow-x-auto text-xs rounded-lg bg-n-alpha-black2 text-n-slate-12 whitespace-pre-wrap break-all"
          ><code>{{ formattedResponseBody }}</code></pre>
        </div>
      </div>
      <p v-else class="text-xs text-n-slate-10">
        {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.PREVIEW.RUN_TEST_HINT') }}
      </p>
    </div>
  </section>
</template>
