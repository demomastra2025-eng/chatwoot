<script setup>
import { computed } from 'vue';
import CopilotThinkingGroup from 'dashboard/components-next/copilot/CopilotThinkingGroup.vue';
import { buildCaptainToolTraceMessages } from './helpers/captainToolTrace';

const props = defineProps({
  additionalAttributes: {
    type: Object,
    default: () => ({}),
  },
});

const traceMessages = computed(() =>
  buildCaptainToolTraceMessages(props.additionalAttributes)
);
</script>

<template>
  <CopilotThinkingGroup
    v-show="traceMessages.length"
    :messages="traceMessages"
    default-collapsed
  />
</template>
