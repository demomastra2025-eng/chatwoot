<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useAlert, useTrack } from 'dashboard/composables';
import { CAMPAIGN_TYPES } from 'shared/constants/campaign.js';
import { CAMPAIGNS_EVENTS } from 'dashboard/helper/AnalyticsHelper/events.js';

import Button from 'dashboard/components-next/button/Button.vue';
import TouchEditorShell from 'dashboard/components-next/Outbound/TouchEditorShell.vue';
import OutboundCampaignForm from './OutboundCampaignForm.vue';

const emit = defineEmits(['close']);

const store = useStore();
const { t } = useI18n();
const formRef = ref(null);

const isCreating = computed(() => formRef.value?.isCreating || false);
const isPreviewing = computed(() => formRef.value?.isPreviewing || false);
const canSubmit = computed(() => formRef.value?.canSubmit || false);

const handleClose = () => emit('close');

const handleSubmit = async campaignDetails => {
  try {
    await store.dispatch('campaigns/create', campaignDetails);
    useTrack(CAMPAIGNS_EVENTS.CREATE_CAMPAIGN, {
      type: CAMPAIGN_TYPES.ONE_OFF,
    });

    useAlert(t('CAMPAIGN.OUTBOUND.CREATE.FORM.API.SUCCESS_MESSAGE'));
    handleClose();
  } catch (error) {
    const errorMessage =
      error?.response?.message ||
      t('CAMPAIGN.OUTBOUND.CREATE.FORM.API.ERROR_MESSAGE');
    useAlert(errorMessage);
  }
};

const runPreview = () => {
  formRef.value?.handlePreview?.();
};

const runCreate = () => {
  formRef.value?.handleSubmit?.();
};
</script>

<template>
  <TouchEditorShell
    model-value
    :title="t('CAMPAIGN.OUTBOUND.CREATE.TITLE')"
    :close-on-outside="false"
    width="md"
    @update:model-value="emit('close')"
    @close="handleClose"
  >
    <OutboundCampaignForm ref="formRef" @submit="handleSubmit" />

    <template #footer>
      <div class="flex w-full items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <Button
            size="sm"
            variant="faded"
            color="slate"
            :label="$t('SCHEDULING.GENERAL.CANCEL')"
            :disabled="isCreating || isPreviewing"
            @click="handleClose"
          />
          <Button
            size="sm"
            variant="outline"
            color="slate"
            :label="$t('CAMPAIGN.PREVIEW.ACTION')"
            :is-loading="isPreviewing"
            :disabled="isCreating || isPreviewing"
            @click="runPreview"
          />
        </div>

        <Button
          size="sm"
          :label="$t('CAMPAIGN.OUTBOUND.CREATE.FORM.BUTTONS.CREATE')"
          :is-loading="isCreating"
          :disabled="isCreating || isPreviewing || !canSubmit"
          @click="runCreate"
        />
      </div>
    </template>
  </TouchEditorShell>
</template>
