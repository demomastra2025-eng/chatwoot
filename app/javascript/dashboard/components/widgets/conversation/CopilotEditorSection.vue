<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import CopilotWorkingState from 'dashboard/components/widgets/conversation/copilot/CopilotWorkingState.vue';

const props = defineProps({
  showCopilotEditor: {
    type: Boolean,
    default: false,
  },
  isGeneratingContent: {
    type: Boolean,
    default: false,
  },
  generatedContent: {
    type: String,
    default: '',
  },
  suggestionMeta: {
    type: Object,
    default: null,
  },
  liveProgress: {
    type: Object,
    default: null,
  },
  pendingActions: {
    type: Array,
    default: () => [],
  },
  actionLoadingById: {
    type: Object,
    default: () => ({}),
  },
  // New customer messages arrived after the suggestion was requested
  stale: {
    type: Boolean,
    default: false,
  },
  // 'legacy_prompt' when the account has no AI agent and the plain prompt ran
  engine: {
    type: String,
    default: null,
  },
  isQueued: {
    type: Boolean,
    default: false,
  },
  // The run found that no reply is needed and prepared only actions
  actionsOnly: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits([
  'focus',
  'blur',
  'contentReady',
  'approveAction',
  'rejectAction',
  'closeAction',
]);

const { t } = useI18n();
const { formatMessage } = useMessageFormatter();

// What a council left to the manager (a part that needs a staff reply, an
// action prepared without a text): shown above the draft.
const operatorNote = computed(() =>
  String(props.suggestionMeta?.operator_note || '').trim()
);

// === Operator Action Approval ("Разрешить / Запретить") ===
const normalizedPendingActions = computed(() => {
  const rawList =
    (Array.isArray(props.pendingActions) && props.pendingActions.length
      ? props.pendingActions
      : null) ||
    props.suggestionMeta?.pending_actions ||
    props.liveProgress?.pending_actions ||
    [];
  if (!Array.isArray(rawList)) return [];
  // A card the run withdrew (a corrected card replaced it) is never shown.
  const superseded = new Set(
    [
      ...(props.suggestionMeta?.superseded_action_ids || []),
      ...(props.liveProgress?.superseded_action_ids || []),
    ].map(String)
  );

  // A card that left the panel (its result was shown, or it was closed) is
  // filtered out; it stays in the list so that nothing brings it back.
  return rawList
    .filter(item => item && (item.action_id || item.actionId))
    .filter(item => !item.dismissed)
    .filter(item => !superseded.has(String(item.action_id || item.actionId)))
    .map(item => {
      const actionId = String(item.action_id || item.actionId);
      const details = Array.isArray(item.details)
        ? item.details.filter(d => d && d.label && d.value)
        : [];
      return {
        raw: item,
        actionId,
        status: String(item.status || 'pending'),
        title: String(item.title || '').trim(),
        description: String(item.description || ''),
        details,
        resultSummary: String(item.result_summary || item.resultSummary || ''),
        loadingState: props.actionLoadingById?.[actionId] || null,
      };
    });
});

// «AI предлагает: Записать на приём»: no agent or tool name
const actionTitleText = action =>
  action.title
    ? t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_SUGGESTS', {
        action: action.title,
      })
    : t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_SUGGESTS_DEFAULT');

const onApproveAction = action => {
  emit('approveAction', action.raw);
};

const onRejectAction = action => {
  emit('rejectAction', action.raw);
};

const onCloseAction = action => {
  emit('closeAction', action.raw);
};

// «Готово» tells that the action is done when the server gave no result line
const approvedLabel = action =>
  action.resultSummary
    ? t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_APPROVED')
    : t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_DONE');

// The panel of a draft and the glow of a run take the focus when they appear,
// so that Ctrl+Enter (insert) and Esc (cancel) work at once: the reply box
// reacts to an Esc pressed inside it, never to one with the focus on the page.
// They do not take it when the manager is already typing elsewhere.
const takeFocus = el => {
  const active = document.activeElement;
  if (active && active !== document.body && !el?.contains?.(active)) return;
  el?.focus?.({ preventScroll: true });
};

const onAfterEnter = el => {
  emit('contentReady');
  takeFocus(el);
};

// A run that is already shown when this section mounts (the manager asked for
// a suggestion, the editor with the focus went away) appears without a
// transition, so the glow takes the focus here.
const workingState = ref(null);
onMounted(() => {
  if (props.isGeneratingContent) takeFocus(workingState.value?.$el);
});
</script>

<template>
  <Transition
    mode="out-in"
    enter-active-class="transition-all duration-300 ease-out"
    enter-from-class="opacity-0 translate-y-2 scale-[0.98]"
    enter-to-class="opacity-100 translate-y-0 scale-100"
    leave-active-class="transition-all duration-200 ease-in"
    leave-from-class="opacity-100 translate-y-0 scale-100"
    leave-to-class="opacity-0 translate-y-2 scale-[0.98]"
    @after-enter="onAfterEnter"
  >
    <div
      v-if="
        (showCopilotEditor || normalizedPendingActions.length) &&
        !isGeneratingContent
      "
      key="copilot-editor"
      class="mb-2 space-y-2 outline-none"
      tabindex="-1"
      data-test="copilot-editor-panel"
      @focus="emit('focus')"
      @blur="emit('blur')"
    >
      <p
        v-if="
          actionsOnly && !showCopilotEditor && normalizedPendingActions.length
        "
        class="mb-0 px-1 text-xs text-n-slate-11"
        role="status"
        data-test="copilot-actions-only-note"
      >
        {{ t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.ACTIONS_ONLY') }}
      </p>

      <!-- A decided card leaves after its result was shown: it fades out
           (a shorter fade without movement under reduced motion) -->
      <TransitionGroup
        v-if="normalizedPendingActions.length"
        tag="div"
        class="space-y-1.5"
        leave-active-class="transition-all duration-200 ease-in motion-reduce:duration-100"
        leave-from-class="opacity-100 translate-y-0 scale-100"
        leave-to-class="opacity-0 translate-y-2 scale-[0.98] motion-reduce:translate-y-0 motion-reduce:scale-100"
        move-class="transition-transform duration-200 motion-reduce:transition-none"
        data-test="copilot-pending-actions"
      >
        <div
          v-for="action in normalizedPendingActions"
          :key="action.actionId"
          class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2.5 text-xs"
          data-test="copilot-action-card"
        >
          <div class="flex flex-wrap items-start justify-between gap-2">
            <div class="min-w-0 flex-1 space-y-1">
              <div
                class="font-semibold text-n-slate-12 leading-4"
                data-test="copilot-action-title"
              >
                {{ actionTitleText(action) }}
              </div>

              <div
                v-if="action.details.length"
                class="flex flex-wrap items-center gap-x-3 gap-y-1 text-n-slate-11"
                data-test="copilot-action-details"
              >
                <span
                  v-for="(detail, idx) in action.details"
                  :key="`${action.actionId}-${idx}`"
                  class="inline-flex items-center gap-1"
                >
                  <span class="text-n-slate-10">{{ detail.label }}:</span>
                  <span class="font-medium text-n-slate-12">
                    {{ detail.value }}
                  </span>
                </span>
              </div>
              <div v-else-if="action.description" class="text-n-slate-11">
                {{ action.description }}
              </div>

              <div
                v-if="action.status === 'approved' && action.resultSummary"
                class="text-n-teal-11 font-medium"
                data-test="copilot-action-result-summary"
              >
                {{ action.resultSummary }}
              </div>
              <!-- One plain line: the text the server returns is for the logs
                   (it can name tools and services), never for the staff -->
              <div
                v-if="action.status === 'failed'"
                class="text-n-ruby-11 font-medium"
                data-test="copilot-action-error"
              >
                {{ t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_FAILED') }}
              </div>
            </div>

            <div class="flex items-center gap-1.5 shrink-0">
              <template
                v-if="
                  action.status === 'pending' ||
                  action.status === 'failed' ||
                  action.status === 'executing'
                "
              >
                <button
                  type="button"
                  class="inline-flex items-center gap-1 rounded-md bg-n-brand-solid px-2.5 py-1 text-xs font-medium text-n-brand-contrast hover:enabled:brightness-110 disabled:opacity-50"
                  data-test="copilot-action-approve"
                  :disabled="
                    Boolean(action.loadingState) ||
                    action.status === 'executing'
                  "
                  @click="onApproveAction(action)"
                >
                  <Icon
                    :icon="
                      action.loadingState === 'approving' ||
                      action.status === 'executing'
                        ? 'i-lucide-loader-circle'
                        : 'i-lucide-check'
                    "
                    class="size-3.5"
                    :class="{
                      'animate-spin':
                        action.loadingState === 'approving' ||
                        action.status === 'executing',
                    }"
                  />
                  <span>
                    {{
                      action.loadingState === 'approving' ||
                      action.status === 'executing'
                        ? t(
                            'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_EXECUTING'
                          )
                        : t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_ALLOW')
                    }}
                  </span>
                </button>
                <button
                  type="button"
                  class="inline-flex items-center gap-1 rounded-md bg-n-alpha-2 px-2.5 py-1 text-xs font-medium text-n-slate-12 hover:enabled:bg-n-alpha-3 disabled:opacity-50"
                  data-test="copilot-action-reject"
                  :disabled="
                    Boolean(action.loadingState) ||
                    action.status === 'executing'
                  "
                  @click="onRejectAction(action)"
                >
                  <span>
                    {{ t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_DENY') }}
                  </span>
                </button>
              </template>
              <span
                v-else-if="action.status === 'approved'"
                class="inline-flex items-center gap-1 rounded-full border border-n-teal-7 bg-n-teal-3/40 px-2.5 py-0.5 text-xs font-medium text-n-teal-11"
                data-test="copilot-action-approved-badge"
              >
                <Icon icon="i-lucide-check-circle-2" class="size-3.5" />
                <span>{{ approvedLabel(action) }}</span>
              </span>
              <span
                v-else-if="action.status === 'rejected'"
                class="inline-flex items-center gap-1 rounded-full border border-n-weak bg-n-alpha-2 px-2.5 py-0.5 text-xs font-medium text-n-slate-11"
                data-test="copilot-action-rejected-badge"
              >
                <Icon icon="i-lucide-ban" class="size-3.5" />
                <span>
                  {{ t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_REJECTED') }}
                </span>
              </span>
              <!-- A failed card stays until the manager closes it -->
              <button
                v-if="action.status === 'failed'"
                type="button"
                class="inline-flex size-6 items-center justify-center rounded-md text-n-slate-11 hover:enabled:bg-n-alpha-2 hover:enabled:text-n-slate-12 disabled:opacity-50"
                :title="t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_CLOSE')"
                :aria-label="
                  t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_CLOSE')
                "
                :disabled="Boolean(action.loadingState)"
                data-test="copilot-action-close"
                @click="onCloseAction(action)"
              >
                <Icon icon="i-lucide-x" class="size-3.5" />
              </button>
            </div>
          </div>
        </div>
      </TransitionGroup>

      <p
        v-if="showCopilotEditor && operatorNote"
        class="mb-0 flex items-start gap-1.5 rounded-lg bg-n-amber-3 px-2.5 py-1.5 text-xs text-n-amber-11 outline outline-1 -outline-offset-1 outline-n-amber-5"
        role="status"
        data-test="copilot-operator-note"
      >
        <Icon icon="i-lucide-user-round" class="mt-0.5 size-3.5 shrink-0" />
        <span class="min-w-0 break-words">{{ operatorNote }}</span>
      </p>
      <p
        v-if="showCopilotEditor && stale"
        class="mb-0 px-1 text-xs text-n-amber-11"
        data-test="copilot-stale-warning"
      >
        {{ t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.STALE_WARNING') }}
      </p>
      <p
        v-if="showCopilotEditor && engine === 'legacy_prompt'"
        class="mb-0 px-1 text-xs text-n-slate-11"
        data-test="copilot-legacy-engine"
      >
        {{ t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.LEGACY_ENGINE') }}
      </p>

      <div
        v-if="showCopilotEditor"
        class="max-h-56 overflow-y-auto px-1 pt-1"
        data-test="copilot-draft"
      >
        <div
          v-dompurify-html="formatMessage(generatedContent, false)"
          class="prose-sm text-sm font-normal leading-relaxed text-n-slate-12 [&>*:last-child]:!mb-0"
        />
      </div>
    </div>
    <CopilotWorkingState
      v-else-if="isGeneratingContent"
      key="loading-state"
      ref="workingState"
      class="outline-none"
      tabindex="-1"
      :progress="liveProgress"
      :queued="isQueued"
      @focus="emit('focus')"
      @blur="emit('blur')"
    />
  </Transition>
</template>
