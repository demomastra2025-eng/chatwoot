<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import CopilotEditor from 'dashboard/components/widgets/WootWriter/CopilotEditor.vue';
import CaptainLoader from 'dashboard/components/widgets/conversation/copilot/CaptainLoader.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import CaptainSenderAvatars from 'dashboard/components-next/message/CaptainSenderAvatars.vue';
import { buildCaptainToolTraceMessages } from 'dashboard/components-next/message/helpers/captainToolTrace';
import {
  councilContributors,
  councilCaption,
} from 'dashboard/components-next/message/helpers/captainSender';

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
  placeholder: {
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
});

const emit = defineEmits([
  'focus',
  'blur',
  'clearSelection',
  'contentReady',
  'send',
  'approveAction',
  'rejectAction',
]);

const { t } = useI18n();
const copilotEditorContent = ref('');

const normalizeAgent = entry => {
  if (!entry || typeof entry !== 'object') return null;
  const name = String(entry.name || entry.agent_name || '').trim();
  if (!name) return null;
  return {
    id: entry.id ?? null,
    name,
    avatarUrl: entry.avatarUrl || entry.avatar_url || '',
    role: entry.role || '',
  };
};

const normalizeAgentList = list => {
  if (!Array.isArray(list)) return [];
  const seen = new Set();
  return list.reduce((acc, item) => {
    const normalized = normalizeAgent(item);
    if (!normalized) return acc;
    const key =
      normalized.id !== null && normalized.id !== undefined
        ? `id:${normalized.id}`
        : `name:${normalized.name.toLowerCase()}`;
    if (seen.has(key)) return acc;
    seen.add(key);
    acc.push(normalized);
    return acc;
  }, []);
};

const normalizeCouncilParts = council => {
  const parts = council?.parts;
  if (!Array.isArray(parts)) return [];
  return parts.map((part, idx) => ({
    id: part.id ?? idx + 1,
    fragment: String(part.fragment || '').trim(),
    patient: String(part.patient || '').trim(),
    status: String(part.status || 'planned').trim(),
    agent: normalizeAgent(part.agent),
  }));
};

// === Live generation state ===
const liveActiveAgent = computed(() =>
  normalizeAgent(props.liveProgress?.active_agent)
);

const liveWorkingAgents = computed(() =>
  normalizeAgentList(props.liveProgress?.working_agents)
);

const liveCouncilParts = computed(() =>
  normalizeCouncilParts(props.liveProgress?.council)
);

// Live steps come from the live progress only: the final trace of a finished
// draft is not "what is happening now" while a follow-up is generating.
const liveSteps = computed(() => {
  const rawTrace = props.liveProgress?.captain_trace;
  if (!rawTrace) return [];
  const messages = buildCaptainToolTraceMessages(
    { captain_trace: rawTrace },
    { reasoningLabel: t('CAPTAIN.COPILOT.REASONING') }
  );
  return messages.slice(-4).map(item => {
    const isReasoning = Boolean(item.message?.reasoning);
    const status = item.message?.status || 'completed';
    const isRunning = status === 'in_progress';
    let icon = 'i-lucide-wrench';
    if (isRunning) {
      icon = 'i-lucide-loader-circle';
    } else if (isReasoning) {
      icon = 'i-lucide-sparkles';
    }
    return {
      id: item.id,
      isReasoning,
      isRunning,
      icon,
      text: isReasoning
        ? item.message.content
        : item.message?.toolName || item.message?.content || '',
      status,
      agentName: item.message?.agentName || '',
    };
  });
});

const liveStatusText = computed(() => {
  if (props.isQueued) {
    return t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.QUEUED');
  }
  const phase = props.liveProgress?.phase;
  // The router is choosing the agent: no agent is thinking yet.
  if (phase === 'routing') {
    return t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.ROUTING');
  }
  if (phase === 'council_running') {
    return t('CONVERSATION.REPLYBOX.COPILOT_TRACE.LIVE_COUNCIL');
  }
  if (phase === 'handoff') {
    return t('CONVERSATION.REPLYBOX.COPILOT_TRACE.LIVE_HANDOFF');
  }
  if (phase === 'tool_running') {
    return liveActiveAgent.value?.name
      ? t('CONVERSATION.REPLYBOX.COPILOT_TRACE.LIVE_AGENT_TOOLS', {
          agent: liveActiveAgent.value.name,
        })
      : t('CONVERSATION.REPLYBOX.COPILOT_TRACE.LIVE_TOOLS');
  }
  if (liveActiveAgent.value?.name) {
    return t('CONVERSATION.REPLYBOX.COPILOT_TRACE.LIVE_AGENT_THINKING', {
      agent: liveActiveAgent.value.name,
    });
  }
  return t('CONVERSATION.REPLYBOX.COPILOT_THINKING');
});

// === Completed state (author only) ===
const primaryAgent = computed(() =>
  normalizeAgent(props.suggestionMeta?.agent)
);

const councilParts = computed(() =>
  normalizeCouncilParts(props.suggestionMeta?.council)
);

const councilContributorsList = computed(() => {
  const explicit = councilContributors({
    contentAttributes: props.suggestionMeta,
  });
  if (explicit.length) return explicit;
  if (!councilParts.value.length) return [];
  return normalizeAgentList(councilParts.value.map(part => part.agent));
});

const isCouncilSuggestion = computed(
  () =>
    councilContributorsList.value.length > 1 || councilParts.value.length > 0
);

const councilHeaderText = computed(() => {
  if (!councilContributorsList.value.length) {
    return t('CONVERSATION.REPLYBOX.COPILOT_TRACE.COUNCIL_FALLBACK');
  }
  return t('CAPTAIN.CHAT_AVATARS.COUNCIL_CAPTION', {
    names: councilCaption(councilContributorsList.value),
  });
});

// What a council left to the manager (a part that needs a staff reply, an
// action prepared without a text): shown above the draft.
const operatorNote = computed(() =>
  String(props.suggestionMeta?.operator_note || '').trim()
);

const hasAuthorAttribution = computed(
  () => Boolean(primaryAgent.value) || isCouncilSuggestion.value
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

  return rawList
    .filter(item => item && (item.action_id || item.actionId))
    .map(item => {
      const actionId = String(item.action_id || item.actionId);
      const agent =
        normalizeAgent(item.agent) ||
        primaryAgent.value ||
        liveActiveAgent.value;
      const details = Array.isArray(item.details)
        ? item.details.filter(d => d && d.label && d.value)
        : [];
      return {
        raw: item,
        actionId,
        toolName: String(item.tool_name || item.toolName || ''),
        status: String(item.status || 'pending'),
        title: String(item.title || item.tool_name || ''),
        description: String(item.description || ''),
        details,
        agent,
        digest: item.digest || null,
        errorMessage: String(item.error_message || item.errorMessage || ''),
        resultSummary: String(item.result_summary || item.resultSummary || ''),
        loadingState: props.actionLoadingById?.[actionId] || null,
      };
    });
});

const actionTitleText = action => {
  if (action.agent?.name) {
    return t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_AGENT_WANTS', {
      agent: action.agent.name,
      action: action.title,
    });
  }
  return t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_DEFAULT_WANTS', {
    action: action.title,
  });
};

const onApproveAction = action => {
  emit('approveAction', action.raw);
};

const onRejectAction = action => {
  emit('rejectAction', action.raw);
};

const partStatusLabel = status => {
  const labels = {
    planned: t('CONVERSATION.REPLYBOX.COPILOT_TRACE.STATUS_PLANNED'),
    running: t('CONVERSATION.REPLYBOX.COPILOT_TRACE.STATUS_RUNNING'),
    answered: t('CONVERSATION.REPLYBOX.COPILOT_TRACE.STATUS_ANSWERED'),
    done: t('CONVERSATION.REPLYBOX.COPILOT_TRACE.STATUS_DONE'),
    needs_information: t(
      'CONVERSATION.REPLYBOX.COPILOT_TRACE.STATUS_NEEDS_INFO'
    ),
    out_of_scope: t('CONVERSATION.REPLYBOX.COPILOT_TRACE.STATUS_OUT_OF_SCOPE'),
    unavailable: t('CONVERSATION.REPLYBOX.COPILOT_TRACE.STATUS_UNAVAILABLE'),
  };
  return labels[status] || status;
};

const partStatusClass = status => {
  if (status === 'answered' || status === 'done') {
    return 'border-n-teal-7 text-n-teal-11 bg-n-teal-3/40';
  }
  if (status === 'running' || status === 'planned') {
    return 'border-n-amber-7 text-n-amber-11 bg-n-amber-3/40';
  }
  if (status === 'needs_information') {
    return 'border-n-iris-7 text-n-iris-11 bg-n-iris-3/40';
  }
  return 'border-n-weak text-n-slate-11 bg-n-alpha-1';
};

const formatPartTitle = part =>
  part.agent?.name ||
  t('CONVERSATION.REPLYBOX.COPILOT_TRACE.PART_FALLBACK', { id: part.id });

const onFocus = () => {
  emit('focus');
};

const onBlur = () => {
  emit('blur');
};

const clearEditorSelection = () => {
  emit('clearSelection');
};

const onSend = () => {
  emit('send', copilotEditorContent.value);
  copilotEditorContent.value = '';
};
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
    @after-enter="emit('contentReady')"
  >
    <div
      v-if="
        (showCopilotEditor || normalizedPendingActions.length) &&
        !isGeneratingContent
      "
      key="copilot-editor"
      class="space-y-2"
      :class="{ 'mb-2': !showCopilotEditor }"
    >
      <div
        v-if="showCopilotEditor && hasAuthorAttribution"
        class="flex items-center gap-2 px-1 py-0.5"
        data-test="copilot-suggestion-attribution"
      >
        <template v-if="isCouncilSuggestion">
          <CaptainSenderAvatars
            v-if="councilContributorsList.length"
            :contributors="councilContributorsList"
            :size="18"
          />
          <span class="text-xs font-medium text-n-iris-11">
            {{ councilHeaderText }}
          </span>
        </template>
        <template v-else-if="primaryAgent">
          <Avatar
            :name="primaryAgent.name"
            :src="primaryAgent.avatarUrl"
            :size="18"
            icon-name="i-woot-captain"
            rounded-full
            class="shrink-0"
          />
          <span class="text-xs text-n-slate-11">
            {{ t('CONVERSATION.REPLYBOX.COPILOT_TRACE.SUGGESTED_BY') }}
            <span class="font-medium text-n-slate-12">
              {{ primaryAgent.name }}
            </span>
          </span>
        </template>
      </div>

      <div
        v-if="normalizedPendingActions.length"
        class="space-y-1.5"
        data-test="copilot-pending-actions"
      >
        <div
          v-for="action in normalizedPendingActions"
          :key="action.actionId"
          class="rounded-lg border border-n-iris-7/50 bg-n-iris-3/30 px-3 py-2.5 text-xs"
          data-test="copilot-action-card"
        >
          <div class="flex flex-wrap items-start justify-between gap-2">
            <div class="flex items-start gap-2 min-w-0 flex-1">
              <Avatar
                v-if="action.agent"
                :name="action.agent.name"
                :src="action.agent.avatarUrl"
                :size="20"
                icon-name="i-woot-captain"
                rounded-full
                class="shrink-0 mt-0.5"
              />
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
                <div
                  v-if="action.status === 'failed' && action.errorMessage"
                  class="text-n-ruby-11 font-medium"
                  data-test="copilot-action-error"
                >
                  {{ action.errorMessage }}
                </div>
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
                  class="inline-flex items-center gap-1 rounded-md bg-n-teal-9 px-2.5 py-1 text-xs font-medium text-white hover:bg-n-teal-10 disabled:opacity-50"
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
                  class="inline-flex items-center gap-1 rounded-md border border-n-weak bg-n-solid-1 px-2.5 py-1 text-xs font-medium text-n-slate-12 hover:bg-n-alpha-2 disabled:opacity-50"
                  data-test="copilot-action-reject"
                  :disabled="
                    Boolean(action.loadingState) ||
                    action.status === 'executing'
                  "
                  @click="onRejectAction(action)"
                >
                  <Icon icon="i-lucide-x" class="size-3.5 text-n-ruby-11" />
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
                <span>
                  {{ t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_APPROVED') }}
                </span>
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
            </div>
          </div>
        </div>
      </div>

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

      <CopilotEditor
        v-if="showCopilotEditor"
        v-model="copilotEditorContent"
        class="copilot-editor"
        :generated-content="generatedContent"
        :placeholder="
          placeholder ||
          t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.REFINE_PLACEHOLDER')
        "
        :min-height="4"
        :enabled-menu-options="[]"
        @focus="onFocus"
        @blur="onBlur"
        @clear-selection="clearEditorSelection"
        @send="onSend"
      />
    </div>
    <div
      v-else-if="isGeneratingContent"
      key="loading-state"
      class="bg-n-iris-5 rounded min-h-[4.75rem] w-full mb-4 px-3.5 py-3 flex flex-col justify-center gap-2"
      data-test="copilot-live-progress"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <CaptainLoader class="text-n-iris-10 size-4 shrink-0" />
          <span class="text-sm font-medium text-n-iris-11">
            {{ liveStatusText }}
          </span>
        </div>

        <div
          v-if="liveWorkingAgents.length"
          class="flex flex-wrap items-center gap-1.5"
          data-test="copilot-live-agents"
        >
          <span
            v-for="agent in liveWorkingAgents"
            :key="agent.id || agent.name"
            class="inline-flex items-center gap-1.5 rounded-full bg-n-solid-1/90 px-2 py-0.5 text-xs text-n-slate-12"
          >
            <Avatar
              :name="agent.name"
              :src="agent.avatarUrl"
              :size="15"
              icon-name="i-woot-captain"
              rounded-full
            />
            <span class="font-medium">{{ agent.name }}</span>
          </span>
        </div>
      </div>

      <div
        v-if="liveCouncilParts.length"
        class="flex flex-wrap items-center gap-1.5"
        data-test="copilot-live-council"
      >
        <div
          v-for="part in liveCouncilParts"
          :key="part.id"
          class="inline-flex items-center gap-1.5 rounded-md border border-n-weak bg-n-solid-1/90 px-2 py-1 text-xs"
        >
          <Avatar
            v-if="part.agent"
            :name="part.agent.name"
            :src="part.agent.avatarUrl"
            :size="14"
            icon-name="i-woot-captain"
            rounded-full
          />
          <span class="font-medium text-n-slate-12">
            {{ formatPartTitle(part) }}
          </span>
          <span
            class="rounded-full border px-1.5 py-0.5 text-[10px] font-medium leading-3"
            :class="partStatusClass(part.status)"
          >
            {{ partStatusLabel(part.status) }}
          </span>
        </div>
      </div>

      <div
        v-if="liveSteps.length"
        class="space-y-1 border-t border-n-iris-6/30 pt-1.5"
        data-test="copilot-live-trace"
      >
        <div
          v-for="step in liveSteps"
          :key="step.id"
          class="flex items-center gap-1.5 text-xs text-n-iris-11 truncate"
        >
          <Icon
            :icon="step.icon"
            class="size-3.5 shrink-0"
            :class="{ 'animate-spin': step.isRunning }"
          />
          <span
            v-if="step.agentName"
            class="shrink-0 font-medium text-n-iris-12"
          >
            {{ step.agentName }}
          </span>
          <span class="truncate text-n-iris-11">
            {{ step.text }}
          </span>
        </div>
      </div>
    </div>
  </Transition>
</template>

<style lang="scss">
.copilot-editor {
  .ProseMirror-menubar {
    display: none;
  }
}
</style>
