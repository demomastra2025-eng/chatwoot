<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useAlert, useTrack } from 'dashboard/composables';
import { CAMPAIGN_TYPES } from 'shared/constants/campaign.js';
import { CAMPAIGNS_EVENTS } from 'dashboard/helper/AnalyticsHelper/events.js';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import LiveChatCampaignForm from 'dashboard/components-next/Campaigns/Pages/CampaignPage/LiveChatCampaign/LiveChatCampaignForm.vue';

const emit = defineEmits(['close']);

const store = useStore();
const { t } = useI18n();
const dialogRef = ref(null);
const formRef = ref(null);
const isSaving = ref(false);
const isSubmitDisabled = computed(
  () => formRef.value?.isSubmitDisabled ?? true
);
onMounted(() => dialogRef.value?.open());

const addCampaign = async campaignDetails => {
  if (isSaving.value) return;
  isSaving.value = true;
  try {
    await store.dispatch('campaigns/create', campaignDetails);

    // tracking this here instead of the store to track the type of campaign
    useTrack(CAMPAIGNS_EVENTS.CREATE_CAMPAIGN, {
      type: CAMPAIGN_TYPES.ONGOING,
    });

    useAlert(t('CAMPAIGN.LIVE_CHAT.CREATE.FORM.API.SUCCESS_MESSAGE'));
    dialogRef.value?.close();
  } catch (error) {
    const errorMessage =
      error?.response?.message ||
      t('CAMPAIGN.LIVE_CHAT.CREATE.FORM.API.ERROR_MESSAGE');
    useAlert(errorMessage);
  } finally {
    isSaving.value = false;
  }
};
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="edit"
    width="md"
    overflow-y-auto
    :title="t('CAMPAIGN.LIVE_CHAT.CREATE.TITLE')"
    :confirm-button-label="t('CAMPAIGN.LIVE_CHAT.CREATE.FORM.BUTTONS.CREATE')"
    :cancel-button-label="t('CAMPAIGN.LIVE_CHAT.CREATE.FORM.BUTTONS.CANCEL')"
    :is-loading="isSaving"
    :disable-confirm-button="isSaving || isSubmitDisabled"
    @confirm="formRef?.submit()"
    @close="emit('close')"
  >
    <LiveChatCampaignForm
      ref="formRef"
      mode="create"
      :show-action-buttons="false"
      @submit="addCampaign"
    />
  </Dialog>
</template>
