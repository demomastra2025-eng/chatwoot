<script setup>
import { PERSONAL_CAMPAIGN_EMPTY_STATE_CONTENT } from './CampaignEmptyStateContent';

import EmptyStateLayout from 'dashboard/components-next/EmptyStateLayout.vue';
import TouchCard from 'dashboard/components-next/Outbound/TouchCard.vue';

defineProps({
  title: {
    type: String,
    default: '',
  },
  subtitle: {
    type: String,
    default: '',
  },
});
</script>

<template>
  <EmptyStateLayout :title="title" :subtitle="subtitle">
    <template #empty-state-item>
      <div class="flex flex-col gap-4 p-px">
        <TouchCard
          v-for="touch in PERSONAL_CAMPAIGN_EMPTY_STATE_CONTENT"
          :key="touch.id"
          :touch="touch"
          :show-actions="false"
        />
      </div>
    </template>
  </EmptyStateLayout>
</template>
