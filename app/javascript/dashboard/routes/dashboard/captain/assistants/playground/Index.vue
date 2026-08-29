<script setup>
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import AssistantPlayground from 'dashboard/components-next/captain/assistant/AssistantPlayground.vue';

const route = useRoute();
const assistantId = computed(() => Number(route.params.assistantId));
</script>

<template>
  <PageLayout
    show-assistant-switcher
    :show-pagination-footer="false"
    :show-know-more="false"
    class="h-full"
  >
    <template #body>
      <AssistantPlayground :assistant-id="assistantId" />
    </template>
  </PageLayout>
</template>
