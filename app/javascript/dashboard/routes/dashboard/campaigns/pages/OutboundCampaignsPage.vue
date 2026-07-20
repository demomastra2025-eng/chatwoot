<script setup>
import { computed, nextTick, ref, watch } from 'vue';
import { useToggle } from '@vueuse/core';
import { useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import CampaignsAPI from 'dashboard/api/campaigns';
import TouchesAPI from 'dashboard/api/touches';
import { usePolicy } from 'dashboard/composables/usePolicy';
import {
  useStore,
  useStoreGetters,
  useMapGetter,
} from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import CampaignList from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignList.vue';
import ConfirmDeleteCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/ConfirmDeleteCampaignDialog.vue';
import CampaignAnalyticsDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignAnalyticsDialog.vue';
import OutboundCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/OutboundCampaign/OutboundCampaignDialog.vue';
import OutboundCampaignEmptyState from 'dashboard/components-next/Campaigns/EmptyState/OutboundCampaignEmptyState.vue';
import ConfirmDeleteTouchDialog from 'dashboard/components-next/Outbound/ConfirmDeleteTouchDialog.vue';
import OutboundWorkspaceLayout from 'dashboard/components-next/Outbound/OutboundWorkspaceLayout.vue';
import TouchEmptyState from 'dashboard/components-next/Outbound/TouchEmptyState.vue';
import TouchEditorDrawer from 'dashboard/components-next/Outbound/TouchEditorDrawer.vue';
import TouchAnalyticsDialog from 'dashboard/components-next/Outbound/TouchAnalyticsDialog.vue';
import TouchList from 'dashboard/components-next/Outbound/TouchList.vue';
import PaginationFooter from 'dashboard/components-next/pagination/PaginationFooter.vue';

const props = defineProps({
  mode: {
    type: String,
    default: '',
  },
});

const MODE_MASS = 'mass';
const MODE_TOUCHES = 'touches';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const { checkPermissions } = usePolicy();
const store = useStore();
const getters = useStoreGetters();

const selectedCampaign = ref(null);
const retryingCampaignId = ref(null);
const cancelingCampaignId = ref(null);
const restartingCampaignId = ref(null);
const resumingCampaignId = ref(null);
const [showOutboundCampaignDialog, toggleOutboundCampaignDialog] = useToggle();

const touches = ref([]);
const TOUCHES_PER_PAGE = 25;
const touchesMeta = ref({
  currentPage: 1,
  perPage: TOUCHES_PER_PAGE,
  totalEntries: 0,
});
const touchesRequestId = ref(0);
const isFetchingTouches = ref(false);
const isTouchEditorOpen = ref(false);
const editingTouch = ref(null);
const mutatingTouchId = ref(null);

const uiFlags = useMapGetter('campaigns/getUIFlags');
const isFetchingCampaigns = computed(() => uiFlags.value.isFetching);

const confirmDeleteCampaignDialogRef = ref(null);
const confirmDeleteTouchDialogRef = ref(null);
const campaignAnalyticsDialogRef = ref(null);
const touchAnalyticsDialogRef = ref(null);

const outboundCampaigns = computed(
  () => getters['campaigns/getOutboundCampaigns'].value
);
const canManageMassCampaigns = computed(() =>
  checkPermissions(['administrator'])
);
const allCampaigns = computed(() => {
  return [...outboundCampaigns.value].sort((left, right) => {
    const leftTime = new Date(
      left.updated_at || left.created_at || 0
    ).getTime();
    const rightTime = new Date(
      right.updated_at || right.created_at || 0
    ).getTime();

    return rightTime - leftTime;
  });
});

const allTouches = computed(() => {
  return [...touches.value].sort((left, right) => {
    const leftTime = new Date(
      left.updated_at || left.created_at || 0
    ).getTime();
    const rightTime = new Date(
      right.updated_at || right.created_at || 0
    ).getTime();

    return rightTime - leftTime;
  });
});

const currentMode = computed(() => {
  return props.mode === MODE_MASS && canManageMassCampaigns.value
    ? MODE_MASS
    : MODE_TOUCHES;
});

const isTouchesMode = computed(() => currentMode.value === MODE_TOUCHES);
const currentTouchPage = computed(() => {
  const page = Number.parseInt(route.query.page, 10);
  return Number.isInteger(page) && page > 0 ? page : 1;
});
const selectedTouch = ref(null);

const pageTitle = computed(() => {
  return isTouchesMode.value
    ? t('SIDEBAR.TOUCHES')
    : t('SIDEBAR.MASS_BROADCASTS');
});

const pageDescription = computed(() => {
  return isTouchesMode.value
    ? t('OUTBOUND_WORKSPACE.TOUCHES.DESCRIPTION')
    : t('CAMPAIGN.OUTBOUND.SECTIONS.OUTBOUND_DESCRIPTION');
});

const touchEditorSelectionMode = computed(() => {
  return editingTouch.value?.remindable?.id ? 'entity' : 'target';
});

const totalItems = computed(() => {
  return isTouchesMode.value
    ? touchesMeta.value.totalEntries
    : allCampaigns.value.length;
});

const metaCountLabel = computed(() => {
  return isTouchesMode.value
    ? t('OUTBOUND_WORKSPACE.TOUCHES.COUNT', { n: totalItems.value })
    : t('CAMPAIGN.OUTBOUND.COUNT', { n: totalItems.value });
});

const isBusy = computed(() => {
  return isTouchesMode.value
    ? isFetchingTouches.value
    : isFetchingCampaigns.value;
});

const handleDelete = campaign => {
  selectedCampaign.value = campaign;
  confirmDeleteCampaignDialogRef.value.dialogRef.open();
};

const handleAnalytics = campaign => {
  selectedCampaign.value = campaign;
  campaignAnalyticsDialogRef.value.open();
};

const handleRetry = async campaign => {
  if (!campaign?.id || retryingCampaignId.value) return;

  retryingCampaignId.value = campaign.id;

  try {
    await CampaignsAPI.retryFailed(campaign.id);
    await store.dispatch('campaigns/get');
  } catch (error) {
    // Preserve current list state on retry failure.
  } finally {
    retryingCampaignId.value = null;
  }
};

const handleCancel = async campaign => {
  if (!campaign?.id || cancelingCampaignId.value) return;

  cancelingCampaignId.value = campaign.id;

  try {
    await CampaignsAPI.cancel(campaign.id);
    await store.dispatch('campaigns/get');
  } catch (error) {
    // Preserve current list state on cancel failure.
  } finally {
    cancelingCampaignId.value = null;
  }
};

const handleRestart = async campaign => {
  if (!campaign?.id || restartingCampaignId.value) return;

  restartingCampaignId.value = campaign.id;

  try {
    await CampaignsAPI.restart(campaign.id);
    await store.dispatch('campaigns/get');
  } catch (error) {
    // Preserve current list state on restart failure.
  } finally {
    restartingCampaignId.value = null;
  }
};

const handleResume = async campaign => {
  if (!campaign?.id || resumingCampaignId.value) return;

  resumingCampaignId.value = campaign.id;

  try {
    await CampaignsAPI.resume(campaign.id);
    await store.dispatch('campaigns/get');
  } catch (error) {
    // Preserve current list state on resume failure.
  } finally {
    resumingCampaignId.value = null;
  }
};

const fetchTouches = async () => {
  const requestId = touchesRequestId.value + 1;
  touchesRequestId.value = requestId;
  isFetchingTouches.value = true;

  try {
    const { data } = await TouchesAPI.get({
      page: currentTouchPage.value,
      per_page: TOUCHES_PER_PAGE,
    });
    if (requestId !== touchesRequestId.value) return;

    touches.value = data.payload || [];
    touchesMeta.value = {
      currentPage: data.meta?.current_page || currentTouchPage.value,
      perPage: data.meta?.per_page || TOUCHES_PER_PAGE,
      totalEntries: data.meta?.count || 0,
    };

    const totalPages = Math.ceil(
      touchesMeta.value.totalEntries / touchesMeta.value.perPage
    );
    if (totalPages > 0 && currentTouchPage.value > totalPages) {
      router.replace({
        query: {
          ...route.query,
          page: totalPages,
        },
      });
    }
  } catch (error) {
    if (requestId !== touchesRequestId.value) return;

    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.LOAD_TOUCHES')
    );
  } finally {
    if (requestId === touchesRequestId.value) {
      isFetchingTouches.value = false;
    }
  }
};

const setTouchPage = page => {
  router.replace({
    query: {
      ...route.query,
      page: page === 1 ? undefined : page,
    },
  });
};

const openCreateTouch = () => {
  editingTouch.value = null;
  isTouchEditorOpen.value = true;
};

const openEditTouch = touch => {
  editingTouch.value = touch;
  isTouchEditorOpen.value = true;
};

const closeTouchEditor = () => {
  isTouchEditorOpen.value = false;
  editingTouch.value = null;
};

const handleTouchSaved = async () => {
  await fetchTouches();
};

const handleTouchAnalytics = async touch => {
  selectedCampaign.value = null;
  editingTouch.value = null;
  selectedTouch.value = touch;
  await nextTick();
  touchAnalyticsDialogRef.value?.open();
};

const approveTouch = async touch => {
  mutatingTouchId.value = touch.id;

  try {
    await TouchesAPI.approve(touch.id);
    await fetchTouches();
    useAlert(t('OUTBOUND_WORKSPACE.TOUCHES.ALL.APPROVE_SUCCESS'));
  } catch (error) {
    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.APPROVE_TOUCH')
    );
  } finally {
    mutatingTouchId.value = null;
  }
};

const cancelTouch = async touch => {
  mutatingTouchId.value = touch.id;

  try {
    await TouchesAPI.cancel(touch.id);
    await fetchTouches();
    useAlert(t('OUTBOUND_WORKSPACE.TOUCHES.ALL.CANCEL_SUCCESS'));
  } catch (error) {
    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.CANCEL_TOUCH')
    );
  } finally {
    mutatingTouchId.value = null;
  }
};

const openDeleteTouch = touch => {
  selectedTouch.value = touch;
  confirmDeleteTouchDialogRef.value?.dialogRef?.open();
};

const handleTouchDeleted = async () => {
  await fetchTouches();
  if (selectedTouch.value?.id === editingTouch.value?.id) {
    closeTouchEditor();
  }
  selectedTouch.value = null;
};

watch(
  () => [isTouchesMode.value, currentTouchPage.value],
  ([isTouches]) => {
    if (isTouches) {
      fetchTouches();
      return;
    }

    store.dispatch('campaigns/get');
  },
  { immediate: true }
);
</script>

<template>
  <OutboundWorkspaceLayout :title="pageTitle" :description="pageDescription">
    <template #meta>
      <span class="text-sm text-n-slate-11">
        {{ metaCountLabel }}
      </span>
    </template>

    <template #actions>
      <Button
        v-if="!isTouchesMode"
        size="sm"
        :label="t('CAMPAIGN.OUTBOUND.ACTIONS.MASS_CAMPAIGN')"
        @click="toggleOutboundCampaignDialog(true)"
      />
      <Button
        v-else
        size="sm"
        :label="t('OUTBOUND_WORKSPACE.TOUCHES.ACTIONS.CREATE')"
        @click="openCreateTouch"
      />
    </template>

    <div
      v-if="isBusy"
      class="flex items-center justify-center py-10 text-n-slate-11"
    >
      <Spinner />
    </div>

    <template v-else-if="isTouchesMode">
      <TouchList
        v-if="allTouches.length"
        :touches="allTouches"
        :mutating-touch-id="mutatingTouchId"
        @edit="openEditTouch"
        @analytics="handleTouchAnalytics"
        @approve="approveTouch"
        @cancel="cancelTouch"
        @delete="openDeleteTouch"
      />
      <TouchEmptyState
        v-else
        :title="$t('OUTBOUND_WORKSPACE.TOUCHES.EMPTY_TITLE')"
        :subtitle="$t('OUTBOUND_WORKSPACE.TOUCHES.EMPTY_SUBTITLE')"
        class="pt-8"
      />
      <PaginationFooter
        v-if="totalItems > touchesMeta.perPage"
        :current-page="currentTouchPage"
        :total-items="totalItems"
        :items-per-page="touchesMeta.perPage"
        @update:current-page="setTouchPage"
      />
    </template>

    <template v-else>
      <CampaignList
        v-if="allCampaigns.length"
        :campaigns="allCampaigns"
        :retrying-campaign-id="retryingCampaignId"
        :canceling-campaign-id="cancelingCampaignId"
        :restarting-campaign-id="restartingCampaignId"
        :resuming-campaign-id="resumingCampaignId"
        @delete="handleDelete"
        @analytics="handleAnalytics"
        @retry="handleRetry"
        @cancel="handleCancel"
        @restart="handleRestart"
        @resume="handleResume"
      />
      <OutboundCampaignEmptyState
        v-else
        :title="t('CAMPAIGN.OUTBOUND.EMPTY_STATE.TITLE')"
        :subtitle="t('CAMPAIGN.OUTBOUND.EMPTY_STATE.SUBTITLE')"
        class="pt-8"
      />
    </template>

    <OutboundCampaignDialog
      v-if="showOutboundCampaignDialog"
      @close="toggleOutboundCampaignDialog(false)"
    />
    <TouchEditorDrawer
      v-model="isTouchEditorOpen"
      :selection-mode="touchEditorSelectionMode"
      :create-label="$t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.CREATE_TITLE')"
      :create-title="$t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.CREATE_TITLE')"
      :edit-title="$t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.EDIT_TITLE')"
      :save-label="$t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.SAVE')"
      :success-created-message="
        $t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.SUCCESS_CREATED')
      "
      :success-updated-message="
        $t('OUTBOUND_WORKSPACE.TOUCHES.EDITOR.SUCCESS_UPDATED')
      "
      :touch="editingTouch"
      @close="closeTouchEditor"
      @saved="handleTouchSaved"
    />
    <ConfirmDeleteCampaignDialog
      ref="confirmDeleteCampaignDialogRef"
      :selected-campaign="selectedCampaign"
    />
    <CampaignAnalyticsDialog
      ref="campaignAnalyticsDialogRef"
      :selected-campaign="selectedCampaign"
    />
    <TouchAnalyticsDialog
      ref="touchAnalyticsDialogRef"
      :selected-touch="selectedTouch"
    />
    <ConfirmDeleteTouchDialog
      ref="confirmDeleteTouchDialogRef"
      :selected-touch="selectedTouch"
      @deleted="handleTouchDeleted"
    />
  </OutboundWorkspaceLayout>
</template>
