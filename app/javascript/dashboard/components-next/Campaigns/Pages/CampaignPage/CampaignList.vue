<script setup>
import CampaignCard from 'dashboard/components-next/Campaigns/CampaignCard/CampaignCard.vue';

defineProps({
  campaigns: {
    type: Array,
    required: true,
  },
  isLiveChatType: {
    type: Boolean,
    default: false,
  },
  retryingCampaignId: {
    type: [String, Number],
    default: null,
  },
  cancelingCampaignId: {
    type: [String, Number],
    default: null,
  },
  restartingCampaignId: {
    type: [String, Number],
    default: null,
  },
  resumingCampaignId: {
    type: [String, Number],
    default: null,
  },
});

const emit = defineEmits([
  'edit',
  'delete',
  'analytics',
  'retry',
  'cancel',
  'restart',
  'resume',
]);

const handleEdit = campaign => emit('edit', campaign);
const handleDelete = campaign => emit('delete', campaign);
const handleAnalytics = campaign => emit('analytics', campaign);
const handleRetry = campaign => emit('retry', campaign);
const handleCancel = campaign => emit('cancel', campaign);
const handleRestart = campaign => emit('restart', campaign);
const handleResume = campaign => emit('resume', campaign);
</script>

<template>
  <div class="flex flex-col gap-4">
    <CampaignCard
      v-for="campaign in campaigns"
      :key="campaign.id"
      :title="campaign.title"
      :message="campaign.message"
      :text-mode="campaign.text_mode"
      :instructions="campaign.instructions"
      :template-params="campaign.template_params"
      :campaign-type="campaign.campaign_type"
      :is-enabled="campaign.enabled"
      :status="campaign.campaign_status"
      :sender="campaign.sender"
      :ai-sender="campaign.ai_sender"
      :inbox="campaign.inbox"
      :scheduled-at="campaign.scheduled_at"
      :latest-run="campaign.latest_run"
      :is-retrying="retryingCampaignId === campaign.id"
      :is-canceling="cancelingCampaignId === campaign.id"
      :is-restarting="restartingCampaignId === campaign.id"
      :is-resuming="resumingCampaignId === campaign.id"
      :is-live-chat-type="
        isLiveChatType || campaign.campaign_type === 'ongoing'
      "
      :show-analytics="
        !(isLiveChatType || campaign.campaign_type === 'ongoing')
      "
      @edit="handleEdit(campaign)"
      @delete="handleDelete(campaign)"
      @analytics="handleAnalytics(campaign)"
      @retry="handleRetry(campaign)"
      @cancel="handleCancel(campaign)"
      @restart="handleRestart(campaign)"
      @resume="handleResume(campaign)"
    />
  </div>
</template>
