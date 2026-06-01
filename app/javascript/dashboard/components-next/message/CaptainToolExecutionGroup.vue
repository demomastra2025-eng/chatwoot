<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import CopilotThinkingGroup from 'dashboard/components-next/copilot/CopilotThinkingGroup.vue';
import { buildCaptainToolTraceMessages } from './helpers/captainToolTrace';

const props = defineProps({
  additionalAttributes: {
    type: Object,
    default: () => ({}),
  },
});

const { t } = useI18n();
const route = useRoute();
const router = useRouter();

const traceMessages = computed(() =>
  buildCaptainToolTraceMessages(props.additionalAttributes, {
    reasoningLabel: t('CAPTAIN.COPILOT.REASONING'),
  })
);

const firstPresent = values =>
  values.find(value => value !== undefined && value !== null && value !== '');

const captainTrace = computed(
  () =>
    props.additionalAttributes?.captainTrace ||
    props.additionalAttributes?.captain_trace ||
    {}
);

const traceQuery = computed(() => {
  const traceId = firstPresent([
    captainTrace.value?.traceId,
    captainTrace.value?.trace_id,
    props.additionalAttributes?.traceId,
    props.additionalAttributes?.trace_id,
  ]);
  const sessionId = firstPresent([
    captainTrace.value?.sessionId,
    captainTrace.value?.session_id,
    props.additionalAttributes?.sessionId,
    props.additionalAttributes?.session_id,
  ]);
  const conversationDisplayId = firstPresent([
    captainTrace.value?.conversationDisplayId,
    captainTrace.value?.conversation_display_id,
    props.additionalAttributes?.conversationDisplayId,
    props.additionalAttributes?.conversation_display_id,
    route.params.conversation_id,
    route.params.conversationId,
  ]);
  const copilotThreadId = firstPresent([
    captainTrace.value?.copilotThreadId,
    captainTrace.value?.copilot_thread_id,
    props.additionalAttributes?.copilotThreadId,
    props.additionalAttributes?.copilot_thread_id,
  ]);

  const query = {
    tab: 'traces',
    ...(traceId ? { trace_id: traceId } : {}),
    ...(sessionId ? { session_id: sessionId } : {}),
    ...(conversationDisplayId
      ? { conversation_display_id: conversationDisplayId }
      : {}),
    ...(copilotThreadId ? { copilot_thread_id: copilotThreadId } : {}),
  };

  return Object.keys(query).length > 1 ? query : null;
});

const openFullTrace = () => {
  if (!traceQuery.value) return;

  router.push({
    name: 'captain_observability_index',
    params: { accountId: route.params.accountId },
    query: traceQuery.value,
  });
};
</script>

<template>
  <div v-show="traceMessages.length" class="flex flex-col gap-1.5">
    <CopilotThinkingGroup :messages="traceMessages" default-collapsed />
    <button
      v-if="traceQuery"
      type="button"
      class="inline-flex w-fit items-center gap-1.5 text-xs font-medium text-n-slate-10 transition-colors hover:text-n-slate-12"
      @click="openFullTrace"
    >
      <i class="i-lucide-route h-3.5 w-3.5" />
      <span>{{ t('CAPTAIN.COPILOT.TOOL_TRACE.OPEN_TRACE') }}</span>
    </button>
  </div>
</template>
