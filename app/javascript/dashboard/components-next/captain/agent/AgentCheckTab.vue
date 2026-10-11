<script setup>
import { computed } from 'vue';
import AssistantPlayground from 'dashboard/components-next/captain/assistant/AssistantPlayground.vue';

const props = defineProps({
  assistant: { type: Object, required: true },
  accountId: { type: [String, Number], default: '' },
});

const assistantId = computed(() => Number(props.assistant?.id) || 0);
</script>

<template>
  <!-- On desktop the chat fills a fixed tall area; on phones the playground
       stacks its side panel above a chat column with its own height. -->
  <div
    class="flex min-h-[32rem] w-full flex-col lg:h-[calc(100vh-14rem)]"
    data-testid="agent-check-tab"
  >
    <AssistantPlayground
      v-if="assistantId"
      :assistant-id="assistantId"
      :account-id="accountId"
      class="min-h-0 flex-1"
    />
  </div>
</template>
