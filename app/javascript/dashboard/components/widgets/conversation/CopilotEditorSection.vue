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

const liveSteps = computed(() => {
  const rawTrace = props.liveProgress?.captain_trace || props.captainTrace;
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

const hasAuthorAttribution = computed(
  () => Boolean(primaryAgent.value) || isCouncilSuggestion.value
);

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
      v-if="showCopilotEditor && !isGeneratingContent"
      key="copilot-editor"
      class="space-y-1.5"
    >
      <div
        v-if="hasAuthorAttribution"
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
