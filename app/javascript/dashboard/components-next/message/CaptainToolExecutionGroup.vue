<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import CopilotThinkingGroup from 'dashboard/components-next/copilot/CopilotThinkingGroup.vue';
import { buildCaptainToolTraceMessages } from './helpers/captainToolTrace';

const props = defineProps({
  additionalAttributes: {
    type: Object,
    default: () => ({}),
  },
});

const { t } = useI18n();

const traceMessages = computed(() =>
  buildCaptainToolTraceMessages(props.additionalAttributes, {
    reasoningLabel: t('CAPTAIN.COPILOT.REASONING'),
  })
);
</script>

<template>
  <div v-show="traceMessages.length" class="flex flex-col gap-1.5">
    <CopilotThinkingGroup :messages="traceMessages" default-collapsed />
  </div>
</template>
