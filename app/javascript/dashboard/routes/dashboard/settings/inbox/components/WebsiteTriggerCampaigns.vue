<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import {
  useMapGetter,
  useStore,
  useStoreGetters,
} from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import LiveChatCampaignForm from 'dashboard/components-next/Campaigns/Pages/CampaignPage/LiveChatCampaign/LiveChatCampaignForm.vue';
import EditLiveChatCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/LiveChatCampaign/EditLiveChatCampaignDialog.vue';

const props = defineProps({
  inbox: {
    type: Object,
    required: true,
  },
});

const { t } = useI18n();
const store = useStore();
const getters = useStoreGetters();
const uiFlags = useMapGetter('campaigns/getUIFlags');

const createDialogRef = ref(null);
const createFormRef = ref(null);
const editDialogRef = ref(null);
const selectedCampaign = ref(null);

const isLoading = computed(() => uiFlags.value.isFetching);
const isCreating = computed(() => uiFlags.value.isCreating);

const websiteTriggerCampaigns = computed(() => {
  const liveChatCampaigns =
    getters['campaigns/getLiveChatCampaigns'].value || [];

  return liveChatCampaigns
    .filter(campaign => campaign.inbox?.id === props.inbox?.id)
    .sort((left, right) => {
      const leftTime = new Date(
        left.updated_at || left.created_at || 0
      ).getTime();
      const rightTime = new Date(
        right.updated_at || right.created_at || 0
      ).getTime();

      return rightTime - leftTime;
    });
});

const isCreateDisabled = computed(() => {
  return isCreating.value || createFormRef.value?.isSubmitDisabled;
});

const senderLabel = campaign => {
  return campaign.sender?.name || t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.BOT');
};

const triggerSummary = campaign => {
  const url = campaign.trigger_rules?.url || '—';
  const timeOnPage = campaign.trigger_rules?.time_on_page;

  if (timeOnPage === undefined || timeOnPage === null || timeOnPage === '') {
    return url;
  }

  return t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.SUMMARY', {
    seconds: timeOnPage,
    url,
  });
};

const statusLabel = campaign => {
  return campaign.enabled
    ? t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.STATUS.ENABLED')
    : t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.STATUS.DISABLED');
};

const statusClass = campaign => {
  return campaign.enabled
    ? 'bg-n-teal-9/10 text-n-teal-11'
    : 'bg-n-alpha-2 text-n-slate-11';
};

const openCreateDialog = () => {
  createDialogRef.value?.open();
};

const openEditDialog = campaign => {
  selectedCampaign.value = campaign;
  editDialogRef.value?.dialogRef.open();
};

const fetchCampaigns = async () => {
  await store.dispatch('campaigns/get');
};

const createCampaign = async () => {
  try {
    await store.dispatch(
      'campaigns/create',
      createFormRef.value.prepareCampaignDetails()
    );

    useAlert(t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.CREATE_SUCCESS'));
    createDialogRef.value.close();
  } catch (error) {
    const errorMessage =
      error?.response?.message ||
      t('CAMPAIGN.LIVE_CHAT.CREATE.FORM.API.ERROR_MESSAGE');
    useAlert(errorMessage);
  }
};

onMounted(fetchCampaigns);

watch(
  () => props.inbox?.id,
  inboxId => {
    if (inboxId) {
      fetchCampaigns();
    }
  }
);
</script>

<template>
  <div
    class="mt-6 rounded-2xl bg-n-surface-1 p-4 outline outline-1 outline-n-container"
  >
    <div
      class="flex flex-col gap-4 md:flex-row md:items-start md:justify-between"
    >
      <div class="min-w-0">
        <h4 class="mb-1 text-base font-medium text-n-slate-12">
          {{ $t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.TITLE') }}
        </h4>
        <p class="mb-0 text-sm leading-6 text-n-slate-11">
          {{ $t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.DESCRIPTION') }}
        </p>
      </div>

      <Button
        size="sm"
        :label="$t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.CREATE')"
        class="md:flex-shrink-0"
        @click="openCreateDialog"
      />
    </div>

    <div
      v-if="isLoading"
      class="flex items-center justify-center py-8 text-n-slate-11"
    >
      <Spinner />
    </div>

    <div
      v-else-if="!websiteTriggerCampaigns.length"
      class="mt-4 rounded-xl bg-n-alpha-1 px-4 py-5"
    >
      <p class="mb-1 text-sm font-medium text-n-slate-12">
        {{ $t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.EMPTY_TITLE') }}
      </p>
      <p class="mb-0 text-sm leading-6 text-n-slate-11">
        {{ $t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.EMPTY_DESCRIPTION') }}
      </p>
    </div>

    <div v-else class="mt-4 grid gap-3">
      <article
        v-for="campaign in websiteTriggerCampaigns"
        :key="campaign.id"
        class="rounded-xl bg-n-alpha-1 px-4 py-4"
      >
        <div
          class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <p class="mb-0 text-sm font-medium text-n-slate-12">
                {{ campaign.title }}
              </p>
              <span
                class="inline-flex rounded-full px-2.5 py-1 text-xs font-medium"
                :class="statusClass(campaign)"
              >
                {{ statusLabel(campaign) }}
              </span>
            </div>

            <p class="mt-2 mb-0 text-sm leading-6 text-n-slate-11">
              {{ campaign.message }}
            </p>

            <div
              class="mt-3 flex flex-wrap items-center gap-2 text-xs text-n-slate-11"
            >
              <span>{{ triggerSummary(campaign) }}</span>
              <span>•</span>
              <span>
                {{
                  $t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.SENDER', {
                    sender: senderLabel(campaign),
                  })
                }}
              </span>
            </div>
          </div>

          <div class="flex items-center gap-2 lg:flex-shrink-0">
            <Button
              size="sm"
              slate
              :label="$t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.EDIT')"
              @click="openEditDialog(campaign)"
            />
          </div>
        </div>
      </article>
    </div>

    <Dialog
      ref="createDialogRef"
      :title="$t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.CREATE_DIALOG_TITLE')"
      :description="
        $t('INBOX_MGMT.WIDGET_TRIGGER_CAMPAIGNS.CREATE_DIALOG_DESCRIPTION')
      "
      :is-loading="isCreating"
      :disable-confirm-button="isCreateDisabled"
      overflow-y-auto
      @confirm="createCampaign"
    >
      <LiveChatCampaignForm
        ref="createFormRef"
        mode="create"
        :locked-inbox-id="inbox.id"
        :show-action-buttons="false"
      />
    </Dialog>

    <EditLiveChatCampaignDialog
      ref="editDialogRef"
      :selected-campaign="selectedCampaign"
    />
  </div>
</template>
