<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Input from 'dashboard/components-next/input/Input.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';

const props = defineProps({
  modelValue: {
    type: Object,
    required: true,
  },
  httpMethod: {
    type: String,
    required: true,
  },
  paramSchema: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();
const showErrors = ref(false);

const paginationModeOptions = computed(() => [
  {
    value: 'page_parameter',
    label: t(
      'CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.PAGINATION.MODES.PAGE_PARAMETER'
    ),
  },
  {
    value: 'next_url',
    label: t(
      'CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.PAGINATION.MODES.NEXT_URL'
    ),
  },
]);

const arrayParameterOptions = computed(() =>
  props.paramSchema
    .filter(
      parameter =>
        parameter.type === 'array' &&
        (parameter.source || 'agent') === 'agent' &&
        parameter.name?.trim()
    )
    .map(parameter => ({
      value: parameter.name,
      label: parameter.name,
    }))
);

const isMutatingMethod = computed(() =>
  ['POST', 'PUT', 'PATCH', 'DELETE'].includes(props.httpMethod)
);

const updateOption = (section, key, value) => {
  emit('update:modelValue', {
    ...props.modelValue,
    [section]: {
      ...props.modelValue[section],
      [key]: value,
    },
  });
};

const updateNumberOption = (section, key, value) => {
  const normalizedValue = value === '' ? '' : Number(value);
  updateOption(section, key, normalizedValue);
};

const updatePaginationEnabled = enabled => {
  const nextOptions = {
    ...props.modelValue,
    pagination: {
      ...props.modelValue.pagination,
      enabled,
    },
  };

  if (enabled) {
    nextOptions.batching = {
      ...props.modelValue.batching,
      enabled: false,
    };
  }

  emit('update:modelValue', nextOptions);
};

const updateBatchingEnabled = enabled => {
  const nextOptions = {
    ...props.modelValue,
    batching: {
      ...props.modelValue.batching,
      enabled,
    },
  };

  if (enabled) {
    nextOptions.pagination = {
      ...props.modelValue.pagination,
      enabled: false,
    };
  }

  emit('update:modelValue', nextOptions);
};

const retryStatuses = computed(() =>
  (props.modelValue.retry?.statuses || []).join(', ')
);

const updateRetryStatuses = value => {
  const statuses = String(value)
    .split(',')
    .map(status => status.trim())
    .filter(Boolean)
    .map(status => {
      const numericStatus = Number(status);
      return Number.isInteger(numericStatus) ? numericStatus : status;
    });
  updateOption('retry', 'statuses', statuses);
};

const isIntegerInRange = (value, min, max) =>
  Number.isInteger(value) && value >= min && value <= max;
const jsonPathPattern = /^[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*$/;
const queryParameterPattern = /^[a-zA-Z_][a-zA-Z0-9_.[\]-]*$/;
const isOptionalJsonPath = value => {
  if (value === null || value === undefined) {
    return true;
  }

  return (
    typeof value === 'string' && (!value.trim() || jsonPathPattern.test(value))
  );
};

const validationErrors = computed(() => {
  const errors = [];
  const options = props.modelValue;

  if (!isIntegerInRange(options.timeout?.open_seconds, 1, 30)) {
    errors.push(
      t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.OPEN_TIMEOUT')
    );
  }
  if (!isIntegerInRange(options.timeout?.read_seconds, 1, 120)) {
    errors.push(
      t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.READ_TIMEOUT')
    );
  }

  if (!isIntegerInRange(options.retry?.max_attempts, 1, 3)) {
    errors.push(
      t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.RETRY_ATTEMPTS')
    );
  }
  if (!isIntegerInRange(options.retry?.backoff_ms, 0, 2000)) {
    errors.push(t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.INTERVAL'));
  }
  const allowedStatuses = [408, 425, 429, 500, 502, 503, 504];
  if (
    !options.retry?.statuses?.length ||
    options.retry.statuses.some(status => !allowedStatuses.includes(status))
  ) {
    errors.push(
      t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.RETRY_STATUSES')
    );
  }
  if (
    options.retry?.enabled &&
    isMutatingMethod.value &&
    !options.idempotency?.enabled
  ) {
    errors.push(t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.IDEMPOTENCY'));
  }

  if (!isIntegerInRange(options.redirects?.max_redirects, 1, 5)) {
    errors.push(t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.REDIRECTS'));
  }

  if (options.pagination?.enabled) {
    if (props.httpMethod !== 'GET') {
      errors.push(
        t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.PAGINATION_METHOD')
      );
    }
    if (options.batching?.enabled) {
      errors.push(
        t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.FLOW_CONFLICT')
      );
    }
    if (!['page_parameter', 'next_url'].includes(options.pagination.mode)) {
      errors.push(
        t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.PAGINATION_MODE')
      );
    }
    if (!isIntegerInRange(options.pagination.start_page, 0, 1000000)) {
      errors.push(
        t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.START_PAGE')
      );
    }
    if (!isIntegerInRange(options.pagination.max_pages, 1, 25)) {
      errors.push(t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.MAX_PAGES'));
    }
    if (!isIntegerInRange(options.pagination.interval_ms, 0, 5000)) {
      errors.push(t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.INTERVAL'));
    }
    if (
      options.pagination.mode === 'next_url' &&
      !options.pagination.next_url_path?.trim()
    ) {
      errors.push(
        t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.NEXT_URL_PATH')
      );
    }
    if (
      options.pagination.mode === 'page_parameter' &&
      !queryParameterPattern.test(options.pagination.parameter_name || '')
    ) {
      errors.push(
        t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.PAGE_PARAMETER')
      );
    }
    if (
      !isOptionalJsonPath(options.pagination.items_path) ||
      !isOptionalJsonPath(options.pagination.next_url_path)
    ) {
      errors.push(t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.JSON_PATH'));
    }
  }

  if (options.batching?.enabled) {
    if (
      !arrayParameterOptions.value.some(
        parameter => parameter.value === options.batching.items_parameter
      )
    ) {
      errors.push(
        t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.BATCH_PARAMETER')
      );
    }
    if (!isIntegerInRange(options.batching.batch_size, 1, 100)) {
      errors.push(
        t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.BATCH_SIZE')
      );
    }
    if (!isIntegerInRange(options.batching.interval_ms, 0, 5000)) {
      errors.push(t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.ERRORS.INTERVAL'));
    }
  }

  return [...new Set(errors)];
});

const validate = () => {
  showErrors.value = true;
  return validationErrors.value.length === 0;
};

defineExpose({ validate });
</script>

<template>
  <details class="rounded-lg border border-n-weak bg-n-alpha-1">
    <summary
      class="flex cursor-pointer select-none items-center justify-between px-3 py-3 text-sm font-medium text-n-slate-12"
    >
      <span>{{ t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.TITLE') }}</span>
      <span class="i-lucide-chevron-down size-4 text-n-slate-10" />
    </summary>

    <div class="flex flex-col gap-4 border-t border-n-weak p-3">
      <p class="text-xs text-n-slate-11">
        {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.HELP_TEXT') }}
      </p>

      <section class="grid grid-cols-2 gap-3">
        <Input
          :model-value="modelValue.timeout.open_seconds"
          type="number"
          min="1"
          max="30"
          :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.TIMEOUT.OPEN')"
          @update:model-value="
            updateNumberOption('timeout', 'open_seconds', $event)
          "
        />
        <Input
          :model-value="modelValue.timeout.read_seconds"
          type="number"
          min="1"
          max="120"
          :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.TIMEOUT.READ')"
          @update:model-value="
            updateNumberOption('timeout', 'read_seconds', $event)
          "
        />
      </section>

      <section class="flex flex-col gap-3 rounded-lg border border-n-weak p-3">
        <label class="flex cursor-pointer items-start gap-3">
          <Checkbox
            :model-value="modelValue.retry.enabled"
            class="mt-0.5 shrink-0"
            @update:model-value="updateOption('retry', 'enabled', $event)"
          />
          <span class="flex flex-col gap-1">
            <span class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.RETRY.TITLE') }}
            </span>
            <span class="text-xs text-n-slate-11">
              {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.RETRY.HELP_TEXT') }}
            </span>
          </span>
        </label>
        <div v-if="modelValue.retry.enabled" class="grid grid-cols-2 gap-3">
          <Input
            :model-value="modelValue.retry.max_attempts"
            type="number"
            min="1"
            max="3"
            :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.RETRY.ATTEMPTS')"
            @update:model-value="
              updateNumberOption('retry', 'max_attempts', $event)
            "
          />
          <Input
            :model-value="modelValue.retry.backoff_ms"
            type="number"
            min="0"
            max="2000"
            :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.RETRY.BACKOFF')"
            @update:model-value="
              updateNumberOption('retry', 'backoff_ms', $event)
            "
          />
          <Input
            :model-value="retryStatuses"
            class="col-span-2"
            :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.RETRY.STATUSES')"
            placeholder="429, 502, 503, 504"
            @update:model-value="updateRetryStatuses"
          />
        </div>
      </section>

      <section class="grid gap-3 sm:grid-cols-2">
        <label
          class="flex cursor-pointer items-start gap-3 rounded-lg border border-n-weak p-3"
        >
          <Checkbox
            :model-value="modelValue.redirects.enabled"
            class="mt-0.5 shrink-0"
            @update:model-value="updateOption('redirects', 'enabled', $event)"
          />
          <span class="flex flex-1 flex-col gap-1">
            <span class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.REDIRECTS.TITLE') }}
            </span>
            <Input
              v-if="modelValue.redirects.enabled"
              :model-value="modelValue.redirects.max_redirects"
              type="number"
              min="1"
              max="5"
              :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.REDIRECTS.MAX')"
              @update:model-value="
                updateNumberOption('redirects', 'max_redirects', $event)
              "
            />
          </span>
        </label>

        <label
          class="flex cursor-pointer items-start gap-3 rounded-lg border border-n-weak p-3"
        >
          <Checkbox
            :model-value="modelValue.idempotency.enabled"
            class="mt-0.5 shrink-0"
            @update:model-value="updateOption('idempotency', 'enabled', $event)"
          />
          <span class="flex flex-col gap-1">
            <span class="text-sm font-medium text-n-slate-12">
              {{
                t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.IDEMPOTENCY.TITLE')
              }}
            </span>
            <span class="text-xs text-n-slate-11">
              {{
                t(
                  'CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.IDEMPOTENCY.HELP_TEXT'
                )
              }}
            </span>
          </span>
        </label>
      </section>

      <section class="flex flex-col gap-3 rounded-lg border border-n-weak p-3">
        <label class="flex cursor-pointer items-start gap-3">
          <Checkbox
            :model-value="modelValue.pagination.enabled"
            class="mt-0.5 shrink-0"
            @update:model-value="updatePaginationEnabled"
          />
          <span class="flex flex-col gap-1">
            <span class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.PAGINATION.TITLE') }}
            </span>
            <span class="text-xs text-n-slate-11">
              {{
                t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.PAGINATION.HELP_TEXT')
              }}
            </span>
          </span>
        </label>
        <div
          v-if="modelValue.pagination.enabled"
          class="grid grid-cols-2 gap-3"
        >
          <div class="col-span-2 flex flex-col gap-1">
            <label class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.PAGINATION.MODE') }}
            </label>
            <ComboBox
              :model-value="modelValue.pagination.mode"
              :options="paginationModeOptions"
              @update:model-value="updateOption('pagination', 'mode', $event)"
            />
          </div>
          <Input
            v-if="modelValue.pagination.mode === 'page_parameter'"
            :model-value="modelValue.pagination.parameter_name"
            :label="
              t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.PAGINATION.PARAMETER')
            "
            @update:model-value="
              updateOption('pagination', 'parameter_name', $event)
            "
          />
          <Input
            v-if="modelValue.pagination.mode === 'page_parameter'"
            :model-value="modelValue.pagination.start_page"
            type="number"
            min="0"
            :label="
              t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.PAGINATION.START_PAGE')
            "
            @update:model-value="
              updateNumberOption('pagination', 'start_page', $event)
            "
          />
          <Input
            v-else
            :model-value="modelValue.pagination.next_url_path"
            class="col-span-2"
            :label="
              t(
                'CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.PAGINATION.NEXT_URL_PATH'
              )
            "
            placeholder="links.next"
            @update:model-value="
              updateOption('pagination', 'next_url_path', $event)
            "
          />
          <Input
            :model-value="modelValue.pagination.items_path"
            :label="
              t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.PAGINATION.ITEMS_PATH')
            "
            placeholder="data.items"
            @update:model-value="
              updateOption('pagination', 'items_path', $event)
            "
          />
          <Input
            :model-value="modelValue.pagination.max_pages"
            type="number"
            min="1"
            max="25"
            :label="
              t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.PAGINATION.MAX_PAGES')
            "
            @update:model-value="
              updateNumberOption('pagination', 'max_pages', $event)
            "
          />
          <Input
            :model-value="modelValue.pagination.interval_ms"
            type="number"
            min="0"
            max="5000"
            :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.INTERVAL')"
            @update:model-value="
              updateNumberOption('pagination', 'interval_ms', $event)
            "
          />
        </div>
      </section>

      <section class="flex flex-col gap-3 rounded-lg border border-n-weak p-3">
        <label class="flex cursor-pointer items-start gap-3">
          <Checkbox
            :model-value="modelValue.batching.enabled"
            class="mt-0.5 shrink-0"
            @update:model-value="updateBatchingEnabled"
          />
          <span class="flex flex-col gap-1">
            <span class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.BATCHING.TITLE') }}
            </span>
            <span class="text-xs text-n-slate-11">
              {{
                t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.BATCHING.HELP_TEXT')
              }}
            </span>
          </span>
        </label>
        <div v-if="modelValue.batching.enabled" class="grid grid-cols-2 gap-3">
          <div class="col-span-2 flex flex-col gap-1">
            <label class="text-sm font-medium text-n-slate-12">
              {{
                t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.BATCHING.PARAMETER')
              }}
            </label>
            <ComboBox
              :model-value="modelValue.batching.items_parameter"
              :options="arrayParameterOptions"
              @update:model-value="
                updateOption('batching', 'items_parameter', $event)
              "
            />
          </div>
          <Input
            :model-value="modelValue.batching.batch_size"
            type="number"
            min="1"
            max="100"
            :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.BATCHING.SIZE')"
            @update:model-value="
              updateNumberOption('batching', 'batch_size', $event)
            "
          />
          <Input
            :model-value="modelValue.batching.interval_ms"
            type="number"
            min="0"
            max="5000"
            :label="t('CAPTAIN.CUSTOM_TOOLS.FORM.HTTP_OPTIONS.INTERVAL')"
            @update:model-value="
              updateNumberOption('batching', 'interval_ms', $event)
            "
          />
        </div>
      </section>

      <ul
        v-if="showErrors && validationErrors.length"
        class="list-disc space-y-1 pl-5 text-xs text-n-ruby-11"
      >
        <li v-for="error in validationErrors" :key="error">{{ error }}</li>
      </ul>
    </div>
  </details>
</template>
