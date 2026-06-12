<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import CopilotThinkingGroup from 'dashboard/components-next/copilot/CopilotThinkingGroup.vue';
import { buildCaptainToolTraceMessages } from './helpers/captainToolTrace';
import { buildCaptainTraceQuery } from './helpers/captainTraceRoute';

const props = defineProps({
  additionalAttributes: {
    type: Object,
    default: () => ({}),
  },
  showOpenTraceAction: {
    type: Boolean,
    default: true,
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

const traceQuery = computed(() =>
  buildCaptainTraceQuery(props.additionalAttributes, route.params)
);

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
    <CopilotThinkingGroup :messages="traceMessages" default-collapsed>
      <template #headerAction>
        <button
          v-if="showOpenTraceAction && traceQuery"
          type="button"
          class="skip-context-menu inline-flex shrink-0 items-center gap-1 whitespace-nowrap text-[0.625rem] font-medium text-n-slate-10 transition-colors hover:text-n-slate-12"
          :title="t('CAPTAIN.COPILOT.TOOL_TRACE.OPEN_TRACE')"
          :aria-label="t('CAPTAIN.COPILOT.TOOL_TRACE.OPEN_TRACE')"
          data-testid="captain-trace-logs"
          @click.stop="openFullTrace"
        >
          <i class="i-lucide-file-text size-3 shrink-0" aria-hidden="true" />
          <span>{{ t('CAPTAIN.COPILOT.TOOL_TRACE.OPEN_TRACE') }}</span>
        </button>
      </template>
    </CopilotThinkingGroup>
  </div>
</template>
