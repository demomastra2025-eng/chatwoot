<script setup>
import { computed, nextTick, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Button from 'dashboard/components-next/button/Button.vue';
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
  // The draft so far, while the AI is still writing it
  streamingText: {
    type: String,
    default: '',
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
      const description = String(item.description || '').trim();
      return {
        raw: item,
        actionId,
        status: String(item.status || 'pending'),
        title: String(item.title || '').trim(),
        description: details.some(
          detail => String(detail.value).trim() === description
        )
          ? ''
          : description,
        details,
        resultSummary: String(item.result_summary || item.resultSummary || ''),
        loadingState: props.actionLoadingById?.[actionId] || null,
      };
    });
});

// The draft as the AI writes it takes the place of the stage sentence, in the
// panel where the final draft will be: when the run ends the text is replaced
// by the final one in the same spot, and only the buttons change. The cards
// wait for the end, as before.
const isStreamingDraft = computed(
  () =>
    props.isGeneratingContent &&
    !props.showCopilotEditor &&
    Boolean(props.streamingText.trim())
);

const showPanel = computed(
  () =>
    isStreamingDraft.value ||
    ((props.showCopilotEditor || normalizedPendingActions.value.length > 0) &&
      !props.isGeneratingContent)
);

const draftText = computed(() =>
  isStreamingDraft.value ? props.streamingText : props.generatedContent
);

// A long draft scrolls inside the panel: while the text grows its end stays in
// view, unless the manager scrolled up to read; the final draft starts at the
// top.
const draftBox = ref(null);
let followStream = true;
const onDraftScroll = () => {
  const el = draftBox.value;
  if (!el) return;
  followStream = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
};
watch(
  () => props.streamingText,
  async () => {
    await nextTick();
    const el = draftBox.value;
    if (el && isStreamingDraft.value && followStream) {
      el.scrollTop = el.scrollHeight;
    }
  }
);
watch(
  () => props.showCopilotEditor,
  async shown => {
    if (!shown) return;
    await nextTick();
    followStream = true;
    if (draftBox.value) draftBox.value.scrollTop = 0;
  }
);

// «AI: Записать на приём»: no agent or tool name
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
      v-if="showPanel"
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
        v-if="normalizedPendingActions.length && !isStreamingDraft"
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
          <div class="flex min-w-0 flex-col gap-2 sm:flex-row sm:items-start">
            <div class="min-w-0 flex-1 space-y-1 break-words">
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
                  class="inline-flex min-w-0 max-w-full flex-wrap items-baseline gap-1"
                >
                  <span class="text-n-slate-10">{{ detail.label }}:</span>
                  <span class="font-medium text-n-slate-12">
                    {{ detail.value }}
                  </span>
                </span>
              </div>
              <div v-if="action.description" class="text-n-slate-11">
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

            <div class="flex flex-wrap items-center gap-2 shrink-0">
              <template
                v-if="
                  action.status === 'pending' ||
                  action.status === 'failed' ||
                  action.status === 'executing'
                "
              >
                <Button
                  type="button"
                  size="sm"
                  variant="solid"
                  color="blue"
                  icon="i-lucide-check"
                  data-test="copilot-action-approve"
                  :is-loading="
                    action.loadingState === 'approving' ||
                    action.status === 'executing'
                  "
                  :label="
                    action.loadingState === 'approving' ||
                    action.status === 'executing'
                      ? t(
                          'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_EXECUTING'
                        )
                      : t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_ALLOW')
                  "
                  :disabled="
                    Boolean(action.loadingState) ||
                    action.status === 'executing'
                  "
                  @click="onApproveAction(action)"
                />
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  color="slate"
                  data-test="copilot-action-reject"
                  :label="t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_DENY')"
                  :is-loading="action.loadingState === 'rejecting'"
                  :disabled="
                    Boolean(action.loadingState) ||
                    action.status === 'executing'
                  "
                  @click="onRejectAction(action)"
                />
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
              <Button
                v-if="action.status === 'failed'"
                type="button"
                size="sm"
                variant="ghost"
                color="slate"
                icon="i-lucide-x"
                :title="t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_CLOSE')"
                :aria-label="
                  t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_CLOSE')
                "
                :disabled="Boolean(action.loadingState)"
                data-test="copilot-action-close"
                @click="onCloseAction(action)"
              />
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
        v-if="showCopilotEditor || isStreamingDraft"
        ref="draftBox"
        class="max-h-56 overflow-y-auto px-1 pt-1"
        :aria-busy="isStreamingDraft"
        data-test="copilot-draft"
        :data-streaming="isStreamingDraft ? 'true' : null"
        @scroll.passive="onDraftScroll"
      >
        <span
          v-if="isStreamingDraft"
          class="sr-only"
          role="status"
          data-test="copilot-draft-writing"
        >
          {{ t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.WRITING') }}
        </span>
        <div
          v-dompurify-html="formatMessage(draftText, false)"
          class="prose-sm text-sm font-normal leading-relaxed text-n-slate-12 [&>*:last-child]:!mb-0"
          :class="{ 'ai-writing': isStreamingDraft }"
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

<style scoped>
/* While the AI is still writing, a small blue dot pulses at the end of the
   text; when the final draft arrives in the same spot, it is gone and the text
   does not move. Under "Reduce motion" it pulses slower, it never stops. */
.ai-writing > :deep(:last-child)::after {
  content: '';
  display: inline-block;
  width: 0.4em;
  height: 0.4em;
  margin-left: 0.35em;
  border-radius: 9999px;
  background: rgb(var(--blue-9));
  animation: ai-writing-pulse 1.2s ease-in-out infinite;
}

@keyframes ai-writing-pulse {
  0%,
  100% {
    opacity: 0.25;
  }

  50% {
    opacity: 1;
  }
}

@media (prefers-reduced-motion: reduce) {
  .ai-writing > :deep(:last-child)::after {
    animation-duration: 2.4s;
  }
}

/* High contrast: the system colour, no animation */
@media (forced-colors: active) {
  .ai-writing > :deep(:last-child)::after {
    background: CanvasText;
    animation: none;
  }
}
</style>
