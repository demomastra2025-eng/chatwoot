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
  <CopilotThinkingGroup
    v-show="traceMessages.length"
    :messages="traceMessages"
    default-collapsed
  />
</template>
