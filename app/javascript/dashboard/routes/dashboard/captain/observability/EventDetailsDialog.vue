<script setup>
/* eslint-disable no-use-before-define */
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import CaptainObservabilityAPI from 'dashboard/api/captain/observability';

const emit = defineEmits([
  'focusTrace',
  'openAssistant',
  'openConversation',
  'openCopilot',
]);
const { t, locale } = useI18n();

const STATUS_CLASSES = Object.freeze({
  pass: 'bg-n-teal-3 text-n-teal-11',
  pass_with_warnings: 'bg-n-amber-3 text-n-amber-11',
  fail: 'bg-n-ruby-3 text-n-ruby-11',
  alerting: 'bg-n-ruby-3 text-n-ruby-11',
  firing: 'bg-n-ruby-3 text-n-ruby-11',
  warning: 'bg-n-amber-3 text-n-amber-11',
  critical: 'bg-n-ruby-3 text-n-ruby-11',
  insufficient_data: 'bg-n-amber-3 text-n-amber-11',
  disabled: 'bg-n-alpha-2 text-n-slate-11',
  not_applicable: 'bg-n-alpha-2 text-n-slate-11',
  ok: 'bg-n-teal-3 text-n-teal-11',
  success: 'bg-n-teal-3 text-n-teal-11',
  completed: 'bg-n-teal-3 text-n-teal-11',
  allowed: 'bg-n-teal-3 text-n-teal-11',
  error: 'bg-n-ruby-3 text-n-ruby-11',
  failed: 'bg-n-ruby-3 text-n-ruby-11',
  blocked: 'bg-n-amber-3 text-n-amber-11',
  flagged: 'bg-n-amber-3 text-n-amber-11',
});

const dialogRef = ref(null);
const selectedEvent = ref(null);
const annotations = ref([]);
const annotationDraft = ref('');
const loadingAnnotations = ref(false);
const savingAnnotation = ref(false);
const deletingAnnotationId = ref(null);

const summaryItems = computed(() => {
  const event = selectedEvent.value;
  if (!event) return [];

  return [
    {
      key: 'event',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.SUMMARY.EVENT'),
      value: event.event_name,
    },
    {
      key: 'feature',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.SUMMARY.FEATURE'),
      value: event.feature,
    },
    {
      key: 'runtime',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.SUMMARY.RUNTIME'),
      value: event.runtime_mode,
    },
    {
      key: 'provider',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.SUMMARY.PROVIDER'),
      value: event.provider,
    },
    {
      key: 'model',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.SUMMARY.MODEL'),
      value: event.model,
    },
    {
      key: 'reason',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.SUMMARY.REASON'),
      value: event.reason ? humanizeIdentifier(event.reason) : null,
    },
  ].filter(item => item.value);
});

const usageItems = computed(() => {
  const event = selectedEvent.value;
  if (!event) return [];

  return [
    {
      key: 'duration',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.DURATION'),
      value: formatDuration(event.duration_ms),
    },
    {
      key: 'tokens',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.TOKENS'),
      value: event.total_tokens ? formatInteger(event.total_tokens) : null,
    },
    {
      key: 'cost',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.COST'),
      value:
        event.estimated_cost !== null && event.estimated_cost !== undefined
          ? formatCurrency(event.estimated_cost)
          : null,
    },
    {
      key: 'prompt_tokens',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.PROMPT_TOKENS'),
      value:
        event.prompt_tokens !== null && event.prompt_tokens !== undefined
          ? formatInteger(event.prompt_tokens)
          : null,
    },
    {
      key: 'completion_tokens',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.COMPLETION_TOKENS'),
      value:
        event.completion_tokens !== null &&
        event.completion_tokens !== undefined
          ? formatInteger(event.completion_tokens)
          : null,
    },
    {
      key: 'thinking_tokens',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.THINKING_TOKENS'),
      value:
        event.thinking_tokens !== null && event.thinking_tokens !== undefined
          ? formatInteger(event.thinking_tokens)
          : null,
    },
  ].filter(item => item.value && item.value !== t('GENERAL.NONE'));
});

const identifierItems = computed(() => {
  const event = selectedEvent.value;
  if (!event) return [];

  return [
    {
      key: 'event_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.EVENT_ID'),
      value: String(event.id),
    },
    {
      key: 'trace_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.TRACE_ID'),
      value: event.trace_id,
    },
    {
      key: 'root_span_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.ROOT_SPAN_ID'),
      value: event.root_span_id,
    },
    {
      key: 'span_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.SPAN_ID'),
      value: event.span_id,
    },
    {
      key: 'parent_span_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.PARENT_SPAN_ID'),
      value: event.parent_span_id,
    },
    {
      key: 'session_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.SESSION_ID'),
      value: event.session_id,
    },
    {
      key: 'assistant_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.ASSISTANT_ID'),
      value: stringValue(event.assistant_id),
    },
    {
      key: 'conversation_display_id',
      label: t(
        'CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.CONVERSATION_DISPLAY_ID'
      ),
      value: stringValue(event.conversation_display_id),
    },
    {
      key: 'conversation_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.CONVERSATION_ID'),
      value: stringValue(event.conversation_id),
    },
    {
      key: 'copilot_thread_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.COPILOT_THREAD_ID'),
      value: stringValue(event.copilot_thread_id),
    },
  ].filter(item => item.value);
});

const contextItems = computed(() => {
  const event = selectedEvent.value;
  if (!event) return [];

  return [
    {
      key: 'trace_name',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.TRACE_NAME'),
      value: event.trace_name,
    },
    {
      key: 'span_kind',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.SPAN_KIND'),
      value: event.span_kind ? humanizeIdentifier(event.span_kind) : null,
    },
    {
      key: 'span_name',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.SPAN_NAME'),
      value: event.span_name,
    },
    {
      key: 'tool_name',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.TOOL_NAME'),
      value: event.tool_name,
    },
    {
      key: 'schema_name',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.SCHEMA_NAME'),
      value: event.schema_name,
    },
    {
      key: 'source',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.SOURCE'),
      value: event.source,
    },
    {
      key: 'channel_type',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.CHANNEL_TYPE'),
      value: event.channel_type,
    },
    {
      key: 'current_agent',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.CURRENT_AGENT'),
      value: event.current_agent,
    },
    {
      key: 'moderation_stage',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.MODERATION_STAGE'),
      value: event.moderation_stage
        ? humanizeIdentifier(event.moderation_stage)
        : null,
    },
    {
      key: 'safety_rule',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.SAFETY_RULE'),
      value: event.safety_rule ? humanizeIdentifier(event.safety_rule) : null,
    },
    {
      key: 'failure_mode',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.FAILURE_MODE'),
      value: event.failure_mode ? humanizeIdentifier(event.failure_mode) : null,
    },
    {
      key: 'flagged_categories',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.FLAGGED_CATEGORIES'),
      value: Array(event.flagged_categories).join(', ') || null,
    },
    {
      key: 'recovery_kind',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.RECOVERY_KIND'),
      value: event.recovery_kind ? humanizeIdentifier(event.recovery_kind) : null,
    },
    {
      key: 'completed_tools_count',
      label: t(
        'CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.COMPLETED_TOOLS_COUNT'
      ),
      value: stringValue(event.completed_tools_count),
    },
    {
      key: 'context_transform_status',
      label: t(
        'CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.CONTEXT_TRANSFORM_STATUS'
      ),
      value: event.context_transform_status
        ? humanizeIdentifier(event.context_transform_status)
        : null,
    },
    {
      key: 'context_window',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.CONTEXT_WINDOW'),
      value:
        event.context_estimated_tokens || event.context_limit
          ? `${formatInteger(event.context_estimated_tokens)} / ${formatInteger(
              event.context_limit
            )}`
          : null,
    },
  ].filter(item => item.value);
});

const flagItems = computed(() => {
  const event = selectedEvent.value;
  if (!event) return [];

  return [
    event.blocked ? t('CAPTAIN.OBSERVABILITY.FLAGS.BLOCKED') : null,
    event.error ? t('CAPTAIN.OBSERVABILITY.FLAGS.ERROR') : null,
    event.tool_failure ? t('CAPTAIN.OBSERVABILITY.FLAGS.TOOL_FAILURE') : null,
    event.schema_invalid
      ? t('CAPTAIN.OBSERVABILITY.FLAGS.SCHEMA_INVALID')
      : null,
    event.moderation_skipped
      ? t('CAPTAIN.OBSERVABILITY.FLAGS.MODERATION_SKIPPED')
      : null,
    event.zero_completion_recovered
      ? t('CAPTAIN.OBSERVABILITY.FLAGS.ZERO_COMPLETION_RECOVERED')
      : null,
  ].filter(Boolean);
});

const detailsText = computed(() => {
  if (!selectedEvent.value) return '';

  const details = selectedEvent.value.details;
  if (details === null || details === undefined) return '';
  if (typeof details === 'string') return details;

  try {
    return JSON.stringify(details, null, 2);
  } catch {
    return String(details);
  }
});

const hasDetails = computed(() => detailsText.value.length > 0);
const availableActions = computed(() => {
  const event = selectedEvent.value;
  if (!event) return [];

  return [
    event.trace_id || event.session_id
      ? {
          key: 'focusTrace',
          label: t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.FOCUS_TRACE'),
        }
      : null,
    event.assistant_id
      ? {
          key: 'openAssistant',
          label: t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.OPEN_ASSISTANT'),
        }
      : null,
    event.conversation_id
      ? {
          key: 'openConversation',
          label: t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.OPEN_CONVERSATION'),
        }
      : null,
    event.copilot_thread_id
      ? {
          key: 'openCopilot',
          label: t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.OPEN_COPILOT'),
        }
      : null,
  ].filter(Boolean);
});

const open = event => {
  selectedEvent.value = event;
  annotationDraft.value = '';
  loadAnnotations();
  dialogRef.value?.open();
};

const close = () => {
  dialogRef.value?.close();
  selectedEvent.value = null;
  annotations.value = [];
  annotationDraft.value = '';
};

const copyDetails = async () => {
  if (!detailsText.value) {
    return;
  }

  try {
    await navigator.clipboard.writeText(detailsText.value);
    useAlert(t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.COPIED'));
  } catch {
    useAlert(t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.COPY_ERROR'));
  }
};

function triggerAction(actionKey) {
  if (!selectedEvent.value) return;

  switch (actionKey) {
    case 'focusTrace':
      emit('focusTrace', selectedEvent.value);
      break;
    case 'openAssistant':
      emit('openAssistant', selectedEvent.value);
      break;
    case 'openConversation':
      emit('openConversation', selectedEvent.value);
      break;
    case 'openCopilot':
      emit('openCopilot', selectedEvent.value);
      break;
    default:
      break;
  }
}

async function loadAnnotations() {
  if (!selectedEvent.value?.id) {
    annotations.value = [];
    return;
  }

  loadingAnnotations.value = true;

  try {
    const response = await CaptainObservabilityAPI.listAnnotations(
      selectedEvent.value.id
    );
    annotations.value = response.data.payload || [];
  } catch {
    annotations.value = [];
    useAlert(t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.LOAD_ERROR'));
  } finally {
    loadingAnnotations.value = false;
  }
}

async function createAnnotation() {
  if (!selectedEvent.value?.id || !annotationDraft.value.trim()) {
    return;
  }

  savingAnnotation.value = true;

  try {
    const response = await CaptainObservabilityAPI.createAnnotation({
      event_id: selectedEvent.value.id,
      body: annotationDraft.value.trim(),
    });
    annotations.value = [response.data.payload, ...annotations.value];
    annotationDraft.value = '';
    useAlert(t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.CREATE_SUCCESS'));
  } catch {
    useAlert(t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.CREATE_ERROR'));
  } finally {
    savingAnnotation.value = false;
  }
}

async function deleteAnnotation(annotationId) {
  if (!selectedEvent.value?.id) return;

  deletingAnnotationId.value = annotationId;

  try {
    await CaptainObservabilityAPI.deleteAnnotation(
      annotationId,
      selectedEvent.value.id
    );
    annotations.value = annotations.value.filter(
      annotation => annotation.id !== annotationId
    );
    useAlert(t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.DELETE_SUCCESS'));
  } catch {
    useAlert(t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.DELETE_ERROR'));
  } finally {
    deletingAnnotationId.value = null;
  }
}

function statusLabel(status) {
  switch (status) {
    case 'pass':
      return t('CAPTAIN.OBSERVABILITY.STATUS.PASS');
    case 'pass_with_warnings':
      return t('CAPTAIN.OBSERVABILITY.STATUS.PASS_WITH_WARNINGS');
    case 'fail':
      return t('CAPTAIN.OBSERVABILITY.STATUS.FAIL');
    case 'insufficient_data':
      return t('CAPTAIN.OBSERVABILITY.STATUS.INSUFFICIENT_DATA');
    case 'disabled':
      return t('CAPTAIN.OBSERVABILITY.STATUS.DISABLED');
    case 'not_applicable':
      return t('CAPTAIN.OBSERVABILITY.STATUS.NOT_APPLICABLE');
    case 'alerting':
      return t('CAPTAIN.OBSERVABILITY.STATUS.ALERTING');
    case 'ok':
      return t('CAPTAIN.OBSERVABILITY.STATUS.OK');
    case 'success':
      return t('CAPTAIN.OBSERVABILITY.STATUS.SUCCESS');
    case 'completed':
      return t('CAPTAIN.OBSERVABILITY.STATUS.COMPLETED');
    case 'allowed':
      return t('CAPTAIN.OBSERVABILITY.STATUS.ALLOWED');
    case 'flagged':
      return t('CAPTAIN.OBSERVABILITY.STATUS.FLAGGED');
    case 'error':
      return t('CAPTAIN.OBSERVABILITY.STATUS.ERROR');
    case 'failed':
      return t('CAPTAIN.OBSERVABILITY.STATUS.FAILED');
    case 'blocked':
      return t('CAPTAIN.OBSERVABILITY.STATUS.BLOCKED');
    default:
      return status ? humanizeIdentifier(status) : t('GENERAL.NONE');
  }
}

function statusClass(status) {
  return STATUS_CLASSES[status] || 'bg-n-alpha-2 text-n-slate-11';
}

function formatDateTime(value) {
  if (!value) return t('GENERAL.NONE');

  try {
    return new Intl.DateTimeFormat(locale.value || undefined, {
      dateStyle: 'medium',
      timeStyle: 'short',
    }).format(new Date(value));
  } catch {
    return value;
  }
}

function formatInteger(value) {
  return Number(value || 0).toLocaleString(locale.value || undefined);
}

function formatCurrency(value) {
  return new Intl.NumberFormat(locale.value || undefined, {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: 4,
  }).format(Number(value || 0));
}

function formatDuration(value) {
  if (value === null || value === undefined) return t('GENERAL.NONE');

  return `${Math.round(Number(value))} ms`;
}

function humanizeIdentifier(value) {
  if (!value) return t('GENERAL.NONE');

  return String(value)
    .replaceAll('_', ' ')
    .replace(/\b\w/g, char => char.toUpperCase());
}

function stringValue(value) {
  return value === null || value === undefined ? null : String(value);
}

defineExpose({ open, close });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="3xl"
    overflow-y-auto
    :title="t('CAPTAIN.OBSERVABILITY.DETAILS.TITLE')"
    :description="t('CAPTAIN.OBSERVABILITY.DETAILS.DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    @close="close"
  >
    <div v-if="selectedEvent" class="grid gap-6">
      <section class="rounded-2xl border border-n-weak bg-n-alpha-2 p-5">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <div class="text-base font-medium text-n-slate-12">
              {{ selectedEvent.event_name }}
            </div>
            <div class="mt-1 text-sm text-n-slate-11">
              {{ formatDateTime(selectedEvent.created_at) }}
            </div>
          </div>
          <span
            class="rounded-full px-2.5 py-1 text-xs font-medium"
            :class="statusClass(selectedEvent.status)"
          >
            {{ statusLabel(selectedEvent.status) }}
          </span>
        </div>
        <div v-if="availableActions.length" class="mt-4 flex flex-wrap gap-2">
          <Button
            v-for="action in availableActions"
            :key="action.key"
            :label="action.label"
            variant="outline"
            color="slate"
            size="sm"
            @click="triggerAction(action.key)"
          />
        </div>
      </section>

      <section class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        <article
          v-for="item in summaryItems"
          :key="item.key"
          class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
        >
          <div class="text-xs uppercase tracking-[0.08em] text-n-slate-10">
            {{ item.label }}
          </div>
          <div class="mt-2 text-sm font-medium text-n-slate-12">
            {{ item.value }}
          </div>
        </article>
      </section>

      <section class="grid gap-6 lg:grid-cols-2">
        <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
          <h3 class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.OBSERVABILITY.DETAILS.SECTIONS.USAGE') }}
          </h3>
          <div class="mt-4 grid gap-3">
            <div
              v-for="item in usageItems"
              :key="item.key"
              class="flex items-start justify-between gap-3 rounded-xl bg-n-alpha-2 p-3"
            >
              <div class="text-sm text-n-slate-11">
                {{ item.label }}
              </div>
              <div class="text-sm font-medium text-n-slate-12">
                {{ item.value }}
              </div>
            </div>
          </div>
        </div>

        <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
          <h3 class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.OBSERVABILITY.DETAILS.SECTIONS.FLAGS') }}
          </h3>
          <div class="mt-4 flex flex-wrap gap-2">
            <span
              v-for="flag in flagItems"
              :key="flag"
              class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
            >
              {{ flag }}
            </span>
            <span v-if="flagItems.length === 0" class="text-sm text-n-slate-11">
              {{ t('CAPTAIN.OBSERVABILITY.FLAGS.NONE') }}
            </span>
          </div>
        </div>
      </section>

      <section class="grid gap-6 lg:grid-cols-2">
        <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
          <h3 class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.OBSERVABILITY.DETAILS.SECTIONS.IDENTIFIERS') }}
          </h3>
          <div class="mt-4 grid gap-3">
            <div
              v-for="item in identifierItems"
              :key="item.key"
              class="flex items-start justify-between gap-3 rounded-xl bg-n-alpha-2 p-3"
            >
              <div class="text-sm text-n-slate-11">
                {{ item.label }}
              </div>
              <div class="text-sm font-medium text-n-slate-12">
                {{ item.value }}
              </div>
            </div>
          </div>
        </div>

        <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
          <h3 class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.OBSERVABILITY.DETAILS.SECTIONS.CONTEXT') }}
          </h3>
          <div class="mt-4 grid gap-3">
            <div
              v-for="item in contextItems"
              :key="item.key"
              class="flex items-start justify-between gap-3 rounded-xl bg-n-alpha-2 p-3"
            >
              <div class="text-sm text-n-slate-11">
                {{ item.label }}
              </div>
              <div class="text-sm font-medium text-n-slate-12">
                {{ item.value }}
              </div>
            </div>
          </div>
        </div>
      </section>

      <section class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
        <div class="flex items-center justify-between gap-3">
          <h3 class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.OBSERVABILITY.DETAILS.SECTIONS.PAYLOAD') }}
          </h3>
          <Button
            v-if="hasDetails"
            :label="t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.COPY_JSON')"
            variant="outline"
            color="slate"
            size="sm"
            @click="copyDetails"
          />
        </div>
        <pre
          v-if="hasDetails"
          class="mt-4 max-h-[28rem] overflow-auto rounded-xl bg-n-alpha-black2 p-4 text-xs text-n-slate-12"
        ><code>{{ detailsText }}</code></pre>
        <div
          v-else
          class="mt-4 rounded-xl bg-n-alpha-2 p-4 text-sm text-n-slate-11"
        >
          {{ t('CAPTAIN.OBSERVABILITY.DETAILS.EMPTY_PAYLOAD') }}
        </div>
      </section>

      <section class="rounded-2xl border border-n-weak bg-n-solid-1 p-5">
        <div class="flex items-center justify-between gap-3">
          <div>
            <h3 class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN.OBSERVABILITY.DETAILS.SECTIONS.ANNOTATIONS') }}
            </h3>
            <p class="mt-1 text-sm text-n-slate-11">
              {{ t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.DESCRIPTION') }}
            </p>
          </div>
        </div>

        <div class="mt-4 grid gap-3">
          <textarea
            v-model="annotationDraft"
            rows="3"
            class="w-full rounded-xl border border-n-weak bg-n-alpha-2 px-3 py-2 text-sm text-n-slate-12 outline-none transition focus:border-n-brand focus:ring-1 focus:ring-n-brand"
            :placeholder="
              t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.PLACEHOLDER')
            "
          />
          <div class="flex justify-end">
            <Button
              :label="t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.ADD_ACTION')"
              size="sm"
              :is-loading="savingAnnotation"
              :disabled="!annotationDraft.trim()"
              @click="createAnnotation"
            />
          </div>
        </div>

        <div v-if="loadingAnnotations" class="mt-4 text-sm text-n-slate-11">
          {{ t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.LOADING') }}
        </div>

        <div v-else-if="annotations.length" class="mt-4 grid gap-3">
          <article
            v-for="annotation in annotations"
            :key="annotation.id"
            class="rounded-xl border border-n-weak bg-n-alpha-2 p-4"
          >
            <div class="flex items-start justify-between gap-3">
              <div>
                <div class="text-sm font-medium text-n-slate-12">
                  {{ annotation.user?.name || t('GENERAL.NONE') }}
                </div>
                <div class="mt-1 text-xs text-n-slate-10">
                  {{
                    t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.META', {
                      email: annotation.user?.email || t('GENERAL.NONE'),
                      createdAt: formatDateTime(annotation.created_at),
                    })
                  }}
                </div>
              </div>
              <Button
                :label="
                  t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.DELETE_ACTION')
                "
                variant="link"
                color="slate"
                size="sm"
                :is-loading="deletingAnnotationId === annotation.id"
                @click="deleteAnnotation(annotation.id)"
              />
            </div>
            <div class="mt-3 whitespace-pre-wrap text-sm text-n-slate-12">
              {{ annotation.body }}
            </div>
          </article>
        </div>

        <div
          v-else
          class="mt-4 rounded-xl bg-n-alpha-2 p-4 text-sm text-n-slate-11"
        >
          {{ t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.EMPTY') }}
        </div>
      </section>
    </div>

    <template #footer>
      <div class="flex items-center justify-end gap-3">
        <Button
          :label="t('DIALOG.BUTTONS.CANCEL')"
          variant="outline"
          color="slate"
          size="sm"
          @click="close"
        />
      </div>
    </template>
  </Dialog>
</template>
