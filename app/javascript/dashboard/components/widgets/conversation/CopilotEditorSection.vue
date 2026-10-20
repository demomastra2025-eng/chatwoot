<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import CopilotEditor from 'dashboard/components/widgets/WootWriter/CopilotEditor.vue';
import CaptainLoader from 'dashboard/components/widgets/conversation/copilot/CaptainLoader.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import CaptainSenderAvatars from 'dashboard/components-next/message/CaptainSenderAvatars.vue';
import CopilotThinkingBlock from 'dashboard/components-next/copilot/CopilotThinkingBlock.vue';
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
  captainTrace: {
    type: Object,
    default: null,
  },
  suggestionMeta: {
    type: Object,
    default: null,
  },
  liveProgress: {
    type: Object,
    default: null,
  },
});

const emit = defineEmits([
  'focus',
  'blur',
  'clearSelection',
  'contentReady',
  'send',
]);

const { t } = useI18n();
const copilotEditorContent = ref('');
const isTraceExpanded = ref(true);

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
    reasoning: String(part.reasoning || '').trim(),
    customerText: String(part.customer_text || part.customerText || '').trim(),
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

const liveHandoffs = computed(() =>
  Array.isArray(props.liveProgress?.handoffs) ? props.liveProgress.handoffs : []
);

const liveCouncilParts = computed(() =>
  normalizeCouncilParts(props.liveProgress?.council)
);

const liveTraceMessages = computed(() => {
  if (!props.liveProgress?.captain_trace) return [];
  return buildCaptainToolTraceMessages(
    { captain_trace: props.liveProgress.captain_trace },
    { reasoningLabel: t('CAPTAIN.COPILOT.REASONING') }
  );
});

const liveStatusText = computed(() => {
  const phase = props.liveProgress?.phase;
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

// === Completed state ===
const primaryAgent = computed(() =>
  normalizeAgent(props.suggestionMeta?.agent)
);

const workingAgentsList = computed(() =>
  normalizeAgentList(props.suggestionMeta?.working_agents)
);

const handoffsList = computed(() =>
  Array.isArray(props.suggestionMeta?.handoffs)
    ? props.suggestionMeta.handoffs
    : []
);

const handoffRouteText = computed(() => {
  if (!handoffsList.value.length) return '';
  const chain = [handoffsList.value[0]?.from];
  handoffsList.value.forEach(item => {
    if (item?.to && chain[chain.length - 1] !== item.to) {
      chain.push(item.to);
    }
  });
  return chain.filter(Boolean).join(' → ');
});

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

const traceMessages = computed(() => {
  if (!props.captainTrace) return [];
  return buildCaptainToolTraceMessages(
    { captain_trace: props.captainTrace },
    { reasoningLabel: t('CAPTAIN.COPILOT.REASONING') }
  );
});

const toolCallCount = computed(
  () => traceMessages.value.filter(item => item?.message?.toolName).length
);

const hasReasoning = computed(() =>
  traceMessages.value.some(item => item?.message?.reasoning)
);

const hasExpandableTrace = computed(
  () =>
    traceMessages.value.length > 0 ||
    councilParts.value.length > 0 ||
    handoffsList.value.length > 0 ||
    workingAgentsList.value.length > 1
);

const hasWorkContext = computed(
  () =>
    Boolean(primaryAgent.value) ||
    isCouncilSuggestion.value ||
    hasExpandableTrace.value
);

const traceSummaryBadges = computed(() => {
  const badges = [];
  if (councilParts.value.length) {
    badges.push(
      t('CONVERSATION.REPLYBOX.COPILOT_TRACE.BADGE_COUNCIL', {
        count: councilParts.value.length,
      })
    );
  }
  if (hasReasoning.value) {
    badges.push(t('CAPTAIN.COPILOT.REASONING'));
  }
  if (toolCallCount.value > 0) {
    badges.push(
      t('CONVERSATION.REPLYBOX.COPILOT_TRACE.BADGE_TOOLS', {
        count: toolCallCount.value,
      })
    );
  }
  return badges;
});

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

const formatRoleBadge = role => {
  if (role === 'council') {
    return `· ${t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ROLE_COUNCIL')}`;
  }
  if (role === 'handoff') {
    return `· ${t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ROLE_HANDOFF')}`;
  }
  if (role === 'entry') {
    return `· ${t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ROLE_ENTRY')}`;
  }
  return '';
};

const formatHandoffPair = handoff => `${handoff.from} → ${handoff.to}`;

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
      v-if="showCopilotEditor && !isGeneratingContent"
      key="copilot-editor"
      class="space-y-2.5"
    >
      <div
        v-if="hasWorkContext"
        class="rounded-lg border border-n-iris-6/60 bg-n-iris-3/30 px-3 py-2"
        data-test="copilot-suggestion-attribution"
      >
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <template v-if="isCouncilSuggestion">
              <CaptainSenderAvatars
                v-if="councilContributorsList.length"
                :contributors="councilContributorsList"
                :size="20"
              />
              <span
                class="inline-flex items-center gap-1 rounded-full bg-n-iris-5 px-2 py-0.5 text-[11px] font-semibold text-n-iris-11"
              >
                <Icon icon="i-lucide-users" class="size-3" />
                {{ councilHeaderText }}
              </span>
            </template>
            <template v-else-if="primaryAgent">
              <Avatar
                :name="primaryAgent.name"
                :src="primaryAgent.avatarUrl"
                :size="20"
                icon-name="i-woot-captain"
                rounded-full
                class="shrink-0"
              />
              <span class="text-xs font-medium text-n-slate-12">
                {{ t('CONVERSATION.REPLYBOX.COPILOT_TRACE.SUGGESTED_BY') }}
                <span class="font-semibold text-n-iris-11">
                  {{ primaryAgent.name }}
                </span>
              </span>
            </template>

            <span
              v-if="handoffRouteText"
              class="inline-flex items-center gap-1 rounded-full bg-n-alpha-2 px-2 py-0.5 text-[11px] text-n-slate-11"
              data-test="copilot-handoff-route"
            >
              <Icon icon="i-lucide-route" class="size-3 text-n-slate-10" />
              {{ handoffRouteText }}
            </span>
          </div>

          <button
            v-if="hasExpandableTrace"
            type="button"
            class="inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-xs font-medium text-n-iris-11 transition-colors hover:bg-n-iris-5/60"
            data-test="copilot-trace-toggle"
            @click="isTraceExpanded = !isTraceExpanded"
          >
            <Icon
              :icon="
                isTraceExpanded
                  ? 'i-lucide-chevron-down'
                  : 'i-lucide-chevron-right'
              "
              class="size-3.5"
            />
            <span>{{
              t('CONVERSATION.REPLYBOX.COPILOT_TRACE.WORK_TRACE')
            }}</span>
            <span
              v-for="badge in traceSummaryBadges"
              :key="badge"
              class="rounded-full bg-n-iris-5/80 px-1.5 py-0.5 text-[10px] font-medium text-n-iris-11"
            >
              {{ badge }}
            </span>
          </button>
        </div>

        <div
          v-if="hasExpandableTrace && isTraceExpanded"
          class="mt-2.5 max-h-60 space-y-2.5 overflow-y-auto border-t border-n-weak pt-2.5"
          data-test="copilot-trace-body"
        >
          <div
            v-if="workingAgentsList.length > 1"
            class="flex flex-wrap items-center gap-1.5"
            data-test="copilot-working-agents"
          >
            <span class="text-[11px] font-medium text-n-slate-11">
              {{ t('CONVERSATION.REPLYBOX.COPILOT_TRACE.WORKING_AGENTS') }}
            </span>
            <span
              v-for="agent in workingAgentsList"
              :key="agent.id || agent.name"
              class="inline-flex items-center gap-1.5 rounded-full border border-n-weak bg-n-solid-1 px-2 py-0.5 text-xs text-n-slate-12"
            >
              <Avatar
                :name="agent.name"
                :src="agent.avatarUrl"
                :size="16"
                icon-name="i-woot-captain"
                rounded-full
              />
              <span class="font-medium">{{ agent.name }}</span>
              <span
                v-if="formatRoleBadge(agent.role)"
                class="text-[10px] text-n-slate-10"
              >
                {{ formatRoleBadge(agent.role) }}
              </span>
            </span>
          </div>

          <div
            v-if="councilParts.length"
            class="space-y-1.5"
            data-test="copilot-council-parts"
          >
            <div
              class="flex items-center gap-1.5 text-xs font-medium text-n-slate-11"
            >
              <Icon icon="i-lucide-users" class="size-3.5 text-n-iris-10" />
              <span>{{
                t('CONVERSATION.REPLYBOX.COPILOT_TRACE.COUNCIL_TITLE')
              }}</span>
            </div>
            <div
              v-for="part in councilParts"
              :key="part.id"
              class="rounded-lg border border-n-weak bg-n-solid-1 p-2.5 text-xs space-y-1"
            >
              <div class="flex flex-wrap items-center justify-between gap-1.5">
                <div class="flex items-center gap-1.5">
                  <Avatar
                    v-if="part.agent"
                    :name="part.agent.name"
                    :src="part.agent.avatarUrl"
                    :size="18"
                    icon-name="i-woot-captain"
                    rounded-full
                  />
                  <span class="font-medium text-n-slate-12">
                    {{ formatPartTitle(part) }}
                  </span>
                </div>
                <span
                  class="rounded-full border px-1.5 py-0.5 text-[10px] font-medium leading-3"
                  :class="partStatusClass(part.status)"
                >
                  {{ partStatusLabel(part.status) }}
                </span>
              </div>
              <p v-if="part.fragment" class="mb-0 text-n-slate-11">
                <span class="font-medium text-n-slate-12">
                  {{ t('CONVERSATION.REPLYBOX.COPILOT_TRACE.TASK_LABEL') }}
                </span>
                {{ part.fragment }}
              </p>
              <p
                v-if="part.reasoning"
                class="mb-0 whitespace-pre-wrap text-n-slate-11"
              >
                <span class="font-medium text-n-slate-12">
                  {{ t('CONVERSATION.REPLYBOX.COPILOT_TRACE.REASONING_LABEL') }}
                </span>
                {{ part.reasoning }}
              </p>
              <p
                v-if="part.customerText"
                class="mb-0 whitespace-pre-wrap text-n-slate-12 bg-n-alpha-1 rounded px-2 py-1"
              >
                {{ part.customerText }}
              </p>
            </div>
          </div>

          <div
            v-if="traceMessages.length"
            class="space-y-1.5 rounded-lg border border-n-weak bg-n-solid-1 p-1.5"
            data-test="copilot-trace-steps"
          >
            <CopilotThinkingBlock
              v-for="item in traceMessages"
              :key="item.id"
              :content="item.message.content"
              :reasoning="item.message.reasoning"
              :tool-name="item.message.toolName"
              :status="item.message.status"
              :input="item.message.input"
              :output="item.message.output"
              :agent-name="item.message.agentName"
            />
          </div>
        </div>
      </div>

      <CopilotEditor
        v-model="copilotEditorContent"
        class="copilot-editor"
        :generated-content="generatedContent"
        :placeholder="placeholder || undefined"
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
      class="bg-n-iris-5 rounded min-h-[4.75rem] w-full mb-4 p-4 flex flex-col gap-3"
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
            class="inline-flex items-center gap-1.5 rounded-full bg-n-solid-1/90 px-2 py-0.5 text-xs text-n-slate-12 shadow-sm"
          >
            <Avatar
              :name="agent.name"
              :src="agent.avatarUrl"
              :size="16"
              icon-name="i-woot-captain"
              rounded-full
            />
            <span class="font-medium">{{ agent.name }}</span>
            <span
              v-if="formatRoleBadge(agent.role)"
              class="text-[10px] text-n-iris-11"
            >
              {{ formatRoleBadge(agent.role) }}
            </span>
          </span>
        </div>
      </div>

      <div
        v-if="liveHandoffs.length"
        class="flex flex-wrap items-center gap-1.5 text-xs text-n-iris-11"
      >
        <Icon icon="i-lucide-route" class="size-3.5 shrink-0" />
        <span
          v-for="(handoff, idx) in liveHandoffs"
          :key="idx"
          class="font-medium"
        >
          {{ formatHandoffPair(handoff) }}
        </span>
      </div>

      <div
        v-if="liveCouncilParts.length"
        class="space-y-1.5 rounded-lg border border-n-iris-6/50 bg-n-solid-1/80 p-2.5"
        data-test="copilot-live-council"
      >
        <div
          class="flex items-center gap-1.5 text-xs font-semibold text-n-iris-11"
        >
          <Icon icon="i-lucide-users" class="size-3.5" />
          <span>{{
            t('CONVERSATION.REPLYBOX.COPILOT_TRACE.COUNCIL_TITLE')
          }}</span>
        </div>
        <div
          v-for="part in liveCouncilParts"
          :key="part.id"
          class="flex flex-col gap-1 rounded-md border border-n-weak bg-n-solid-1 p-2 text-xs"
        >
          <div class="flex items-center justify-between gap-2">
            <div class="flex items-center gap-1.5">
              <Avatar
                v-if="part.agent"
                :name="part.agent.name"
                :src="part.agent.avatarUrl"
                :size="16"
                icon-name="i-woot-captain"
                rounded-full
              />
              <span class="font-medium text-n-slate-12">
                {{ formatPartTitle(part) }}
              </span>
            </div>
            <span
              class="rounded-full border px-1.5 py-0.5 text-[10px] font-medium leading-3"
              :class="partStatusClass(part.status)"
            >
              {{ partStatusLabel(part.status) }}
            </span>
          </div>
          <p v-if="part.fragment" class="mb-0 text-n-slate-11">
            {{ part.fragment }}
          </p>
          <p v-if="part.reasoning" class="mb-0 text-n-slate-11 italic">
            {{ part.reasoning }}
          </p>
        </div>
      </div>

      <div
        v-if="liveTraceMessages.length"
        class="max-h-48 space-y-1 overflow-y-auto rounded-lg border border-n-iris-6/40 bg-n-solid-1/90 p-1.5"
        data-test="copilot-live-trace"
      >
        <CopilotThinkingBlock
          v-for="item in liveTraceMessages"
          :key="item.id"
          :content="item.message.content"
          :reasoning="item.message.reasoning"
          :tool-name="item.message.toolName"
          :status="item.message.status"
          :input="item.message.input"
          :output="item.message.output"
          :agent-name="item.message.agentName"
        />
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
