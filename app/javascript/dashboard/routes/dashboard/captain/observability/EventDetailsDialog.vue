<script setup>
/* eslint-disable no-use-before-define */
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import CaptainObservabilityAPI from 'dashboard/api/captain/observability';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const emit = defineEmits([
  'focusTrace',
  'openAssistant',
  'openConversation',
  'openCopilot',
]);
const { t, locale } = useI18n();
const dialogRef = ref(null);
const event = ref(null);
const annotations = ref([]);
const annotationDraft = ref('');
const loadingAnnotations = ref(false);
const savingAnnotation = ref(false);
const deletingAnnotationId = ref(null);

const summary = computed(() => {
  if (!event.value) return [];

  return [
    [t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.STATUS'), event.value.status],
    [t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.MODEL'), event.value.model],
    [t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.PROVIDER'), event.value.provider],
    [t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.TOOL'), event.value.tool_name],
    [
      t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.DURATION'),
      formatDuration(event.value.duration_ms),
    ],
    [
      t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.TOKENS'),
      event.value.total_tokens,
    ],
    [
      t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.COST'),
      formatCost(event.value.estimated_cost),
    ],
    [
      t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.TIME'),
      formatTimestamp(event.value.created_at),
    ],
  ].filter(
    ([, value]) => value !== null && value !== undefined && value !== ''
  );
});

const selectedEvent = event;
const usageItems = computed(() => {
  const entry = selectedEvent.value;
  if (!entry) return [];

  return [
    {
      key: 'duration',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.DURATION'),
      value: formatDuration(entry.duration_ms),
    },
    {
      key: 'tokens',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.TOKENS'),
      value: entry.total_tokens ? formatInteger(entry.total_tokens) : null,
    },
    {
      key: 'cost',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.COST'),
      value:
        entry.estimated_cost !== null && entry.estimated_cost !== undefined
          ? formatCurrency(entry.estimated_cost)
          : null,
    },
    {
      key: 'prompt_tokens',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.PROMPT_TOKENS'),
      value:
        entry.prompt_tokens !== null && entry.prompt_tokens !== undefined
          ? formatInteger(entry.prompt_tokens)
          : null,
    },
    {
      key: 'completion_tokens',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.COMPLETION_TOKENS'),
      value:
        entry.completion_tokens !== null &&
        entry.completion_tokens !== undefined
          ? formatInteger(entry.completion_tokens)
          : null,
    },
    {
      key: 'thinking_tokens',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.USAGE.THINKING_TOKENS'),
      value:
        entry.thinking_tokens !== null && entry.thinking_tokens !== undefined
          ? formatInteger(entry.thinking_tokens)
          : null,
    },
  ].filter(item => item.value && item.value !== t('GENERAL.NONE'));
});

const identifierItems = computed(() => {
  const entry = selectedEvent.value;
  if (!entry) return [];

  return [
    {
      key: 'event_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.EVENT_ID'),
      value: String(entry.id),
    },
    {
      key: 'trace_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.TRACE_ID'),
      value: entry.trace_id,
    },
    {
      key: 'root_span_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.ROOT_SPAN_ID'),
      value: entry.root_span_id,
    },
    {
      key: 'span_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.SPAN_ID'),
      value: entry.span_id,
    },
    {
      key: 'parent_span_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.PARENT_SPAN_ID'),
      value: entry.parent_span_id,
    },
    {
      key: 'session_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.SESSION_ID'),
      value: entry.session_id,
    },
    {
      key: 'assistant_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.ASSISTANT_ID'),
      value: stringValue(entry.assistant_id),
    },
    {
      key: 'conversation_display_id',
      label: t(
        'CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.CONVERSATION_DISPLAY_ID'
      ),
      value: stringValue(entry.conversation_display_id),
    },
    {
      key: 'conversation_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.CONVERSATION_ID'),
      value: stringValue(entry.conversation_id),
    },
    {
      key: 'copilot_thread_id',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.IDENTIFIERS.COPILOT_THREAD_ID'),
      value: stringValue(entry.copilot_thread_id),
    },
  ].filter(item => item.value);
});

const contextItems = computed(() => {
  const entry = selectedEvent.value;
  if (!entry) return [];

  return [
    {
      key: 'trace_name',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.TRACE_NAME'),
      value: entry.trace_name,
    },
    {
      key: 'span_kind',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.SPAN_KIND'),
      value: entry.span_kind ? humanizeIdentifier(entry.span_kind) : null,
    },
    {
      key: 'span_name',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.SPAN_NAME'),
      value: entry.span_name,
    },
    {
      key: 'tool_name',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.TOOL_NAME'),
      value: entry.tool_name,
    },
    {
      key: 'schema_name',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.SCHEMA_NAME'),
      value: entry.schema_name,
    },
    {
      key: 'source',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.SOURCE'),
      value: entry.source,
    },
    {
      key: 'channel_type',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.CHANNEL_TYPE'),
      value: entry.channel_type,
    },
    {
      key: 'current_agent',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.CURRENT_AGENT'),
      value: entry.current_agent,
    },
    {
      key: 'moderation_stage',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.MODERATION_STAGE'),
      value: entry.moderation_stage
        ? humanizeIdentifier(entry.moderation_stage)
        : null,
    },
    {
      key: 'safety_rule',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.SAFETY_RULE'),
      value: entry.safety_rule ? humanizeIdentifier(entry.safety_rule) : null,
    },
    {
      key: 'failure_mode',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.FAILURE_MODE'),
      value: entry.failure_mode ? humanizeIdentifier(entry.failure_mode) : null,
    },
    {
      key: 'flagged_categories',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.FLAGGED_CATEGORIES'),
      value: Array(entry.flagged_categories).join(', ') || null,
    },
    {
      key: 'recovery_kind',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.RECOVERY_KIND'),
      value: entry.recovery_kind
        ? humanizeIdentifier(entry.recovery_kind)
        : null,
    },
    {
      key: 'completed_tools_count',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.COMPLETED_TOOLS_COUNT'),
      value: stringValue(entry.completed_tools_count),
    },
    {
      key: 'context_transform_status',
      label: t(
        'CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.CONTEXT_TRANSFORM_STATUS'
      ),
      value: entry.context_transform_status
        ? humanizeIdentifier(entry.context_transform_status)
        : null,
    },
    {
      key: 'context_window',
      label: t('CAPTAIN.OBSERVABILITY.DETAILS.CONTEXT.CONTEXT_WINDOW'),
      value:
        entry.context_estimated_tokens || entry.context_limit
          ? `${formatInteger(entry.context_estimated_tokens)} / ${formatInteger(
              entry.context_limit
            )}`
          : null,
    },
  ].filter(item => item.value);
});

const flagItems = computed(() => {
  const entry = selectedEvent.value;
  if (!entry) return [];

  return [
    entry.blocked ? t('CAPTAIN.OBSERVABILITY.FLAGS.BLOCKED') : null,
    entry.error ? t('CAPTAIN.OBSERVABILITY.FLAGS.ERROR') : null,
    entry.tool_failure ? t('CAPTAIN.OBSERVABILITY.FLAGS.TOOL_FAILURE') : null,
    entry.schema_invalid
      ? t('CAPTAIN.OBSERVABILITY.FLAGS.SCHEMA_INVALID')
      : null,
    entry.moderation_skipped
      ? t('CAPTAIN.OBSERVABILITY.FLAGS.MODERATION_SKIPPED')
      : null,
    entry.zero_completion_recovered
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

const availableActions = computed(() => {
  if (!event.value) return [];

  return [
    event.value.trace_id || event.value.session_id
      ? {
          key: 'focusTrace',
          label: t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.FOCUS_TRACE'),
        }
      : null,
    event.value.assistant_id
      ? {
          key: 'openAssistant',
          label: t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.OPEN_ASSISTANT'),
        }
      : null,
    event.value.conversation_id
      ? {
          key: 'openConversation',
          label: t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.OPEN_CONVERSATION'),
        }
      : null,
    event.value.copilot_thread_id
      ? {
          key: 'openCopilot',
          label: t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.OPEN_COPILOT'),
        }
      : null,
  ].filter(Boolean);
});

const formatInteger = value =>
  Number(value || 0).toLocaleString(locale.value || undefined);

const formatCurrency = value =>
  new Intl.NumberFormat(locale.value || undefined, {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: 4,
  }).format(Number(value || 0));

const humanizeIdentifier = value =>
  String(value)
    .replaceAll('_', ' ')
    .replace(/\b\w/g, char => char.toUpperCase());

const stringValue = value =>
  value === null || value === undefined ? null : String(value);

const formatDuration = value => {
  if (value === null || value === undefined) return null;
  return `${Number(value).toLocaleString(locale.value)} ms`;
};

const formatCost = value => {
  if (value === null || value === undefined) return null;
  return new Intl.NumberFormat(locale.value, {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: 6,
  }).format(Number(value));
};

const formatTimestamp = value => {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat(locale.value, {
    dateStyle: 'medium',
    timeStyle: 'medium',
  }).format(date);
};

const title = computed(() =>
  String(event.value?.event_name || t('CAPTAIN.OBSERVABILITY.SIMPLE.EVENT'))
    .replace(/[._-]+/g, ' ')
    .replace(/\b\w/g, character => character.toUpperCase())
);

const open = targetEvent => {
  event.value = targetEvent;
  annotationDraft.value = '';
  loadAnnotations();
  dialogRef.value?.open();
};

const close = () => {
  dialogRef.value?.close();
  event.value = null;
  annotations.value = [];
  annotationDraft.value = '';
};

const copyDetails = async () => {
  try {
    await navigator.clipboard.writeText(detailsText.value);
    useAlert(t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.COPIED'));
  } catch {
    useAlert(t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.COPY_ERROR'));
  }
};

const triggerAction = key => {
  if (key === 'focusTrace') emit('focusTrace', event.value);
  if (key === 'openAssistant') emit('openAssistant', event.value);
  if (key === 'openConversation') emit('openConversation', event.value);
  if (key === 'openCopilot') emit('openCopilot', event.value);
};

async function loadAnnotations() {
  if (!event.value?.id) {
    annotations.value = [];
    return;
  }

  const eventId = event.value.id;
  loadingAnnotations.value = true;
  try {
    const response = await CaptainObservabilityAPI.listAnnotations(eventId);
    if (event.value?.id === eventId) {
      annotations.value = response.data.payload || [];
    }
  } catch {
    if (event.value?.id === eventId) {
      annotations.value = [];
      useAlert(t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.LOAD_ERROR'));
    }
  } finally {
    if (event.value?.id === eventId) loadingAnnotations.value = false;
  }
}

async function createAnnotation() {
  if (!event.value?.id || !annotationDraft.value.trim()) return;

  savingAnnotation.value = true;
  try {
    const response = await CaptainObservabilityAPI.createAnnotation({
      event_id: event.value.id,
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
  if (!event.value?.id) return;

  deletingAnnotationId.value = annotationId;
  try {
    await CaptainObservabilityAPI.deleteAnnotation(
      annotationId,
      event.value.id
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

defineExpose({ open, close });
</script>

<template>
  <Dialog
    ref="dialogRef"
    :title="title"
    :show-confirm-button="false"
    show-close-button
    :close-button-label="t('GENERAL.CLOSE')"
    overflow-y-auto
    width="3xl"
    @close="close"
  >
    <div v-if="event" class="space-y-5">
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div
          v-for="([label, value], index) in summary"
          :key="index"
          class="rounded-lg bg-n-alpha-2 px-3 py-2"
        >
          <div class="text-xs text-n-slate-10">{{ label }}</div>
          <div class="mt-1 break-words text-sm text-n-slate-12">
            {{ value }}
          </div>
        </div>
      </div>

      <div
        v-if="event.error"
        class="rounded-lg bg-n-ruby-3 px-3 py-2 text-sm text-n-ruby-11"
      >
        {{ event.reason || t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.ERROR') }}
      </div>

      <div v-if="availableActions.length" class="flex flex-wrap gap-2">
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

      <section v-if="usageItems.length">
        <h3 class="mb-2 text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.OBSERVABILITY.DETAILS.SECTIONS.USAGE') }}
        </h3>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div
            v-for="item in usageItems"
            :key="item.key"
            class="rounded-lg bg-n-alpha-2 px-3 py-2"
          >
            <div class="text-xs text-n-slate-10">{{ item.label }}</div>
            <div class="mt-1 text-sm text-n-slate-12">{{ item.value }}</div>
          </div>
        </div>
      </section>

      <section>
        <h3 class="mb-2 text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.OBSERVABILITY.DETAILS.SECTIONS.FLAGS') }}
        </h3>
        <div class="flex flex-wrap gap-2">
          <span
            v-for="flag in flagItems"
            :key="flag"
            class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
          >
            {{ flag }}
          </span>
          <span v-if="!flagItems.length" class="text-sm text-n-slate-11">
            {{ t('CAPTAIN.OBSERVABILITY.FLAGS.NONE') }}
          </span>
        </div>
      </section>

      <section
        v-for="section in [
          { key: 'IDENTIFIERS', items: identifierItems },
          { key: 'CONTEXT', items: contextItems },
        ]"
        v-show="section.items.length"
        :key="section.key"
      >
        <h3 class="mb-2 text-sm font-medium text-n-slate-12">
          {{ t(`CAPTAIN.OBSERVABILITY.DETAILS.SECTIONS.${section.key}`) }}
        </h3>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div
            v-for="item in section.items"
            :key="item.key"
            class="rounded-lg bg-n-alpha-2 px-3 py-2"
          >
            <div class="text-xs text-n-slate-10">{{ item.label }}</div>
            <div class="mt-1 break-words text-sm text-n-slate-12">
              {{ item.value }}
            </div>
          </div>
        </div>
      </section>

      <section>
        <div class="mb-2 flex items-center justify-between gap-3">
          <h3 class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.OBSERVABILITY.SIMPLE.DETAILS.DATA') }}
          </h3>
          <Button
            v-if="detailsText"
            :label="t('CAPTAIN.OBSERVABILITY.DETAILS.ACTIONS.COPY_JSON')"
            variant="outline"
            color="slate"
            size="sm"
            @click="copyDetails"
          />
        </div>
        <pre
          v-if="detailsText"
          class="max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-n-alpha-2 p-3 text-xs text-n-slate-11"
        ><code>{{ detailsText }}</code></pre>
        <p v-else class="text-sm text-n-slate-11">
          {{ t('CAPTAIN.OBSERVABILITY.DETAILS.EMPTY_PAYLOAD') }}
        </p>
      </section>

      <section>
        <h3 class="mb-2 text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.OBSERVABILITY.DETAILS.SECTIONS.ANNOTATIONS') }}
        </h3>
        <p class="mb-3 text-sm text-n-slate-11">
          {{ t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.DESCRIPTION') }}
        </p>
        <textarea
          v-model="annotationDraft"
          rows="3"
          class="w-full rounded-lg border border-n-weak bg-n-alpha-2 p-3 text-sm text-n-slate-12"
          :placeholder="
            t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.PLACEHOLDER')
          "
        />
        <div class="mt-2 flex justify-end">
          <Button
            :label="t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.ADD_ACTION')"
            size="sm"
            :is-loading="savingAnnotation"
            :disabled="!annotationDraft.trim()"
            @click="createAnnotation"
          />
        </div>
        <p v-if="loadingAnnotations" class="mt-3 text-sm text-n-slate-11">
          {{ t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.LOADING') }}
        </p>
        <div v-else-if="annotations.length" class="mt-3 space-y-3">
          <article
            v-for="annotation in annotations"
            :key="annotation.id"
            class="rounded-lg bg-n-alpha-2 p-3"
          >
            <div class="flex items-center justify-between gap-2">
              <span class="text-sm text-n-slate-12">{{
                annotation.user?.name || t('GENERAL.NONE')
              }}</span>
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
            <div class="text-xs text-n-slate-10">
              {{
                t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.META', {
                  email: annotation.user?.email || t('GENERAL.NONE'),
                  createdAt: formatTimestamp(annotation.created_at),
                })
              }}
            </div>
            <p class="mt-2 whitespace-pre-wrap text-sm text-n-slate-12">
              {{ annotation.body }}
            </p>
          </article>
        </div>
        <p v-else class="mt-3 text-sm text-n-slate-11">
          {{ t('CAPTAIN.OBSERVABILITY.DETAILS.ANNOTATIONS.EMPTY') }}
        </p>
      </section>
    </div>
  </Dialog>
</template>
