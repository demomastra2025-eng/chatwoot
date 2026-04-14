<script setup>
import { computed, nextTick, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useToggle } from '@vueuse/core';
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
import { useAccount } from 'dashboard/composables/useAccount';

import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import CampaignList from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignList.vue';
import ConfirmDeleteCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/ConfirmDeleteCampaignDialog.vue';
import CampaignAnalyticsDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignAnalyticsDialog.vue';
import OutboundCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/OutboundCampaign/OutboundCampaignDialog.vue';
import OutboundCampaignEmptyState from 'dashboard/components-next/Campaigns/EmptyState/OutboundCampaignEmptyState.vue';
import PersonalCampaignEmptyState from 'dashboard/components-next/Campaigns/EmptyState/PersonalCampaignEmptyState.vue';
import ConfirmDeleteTouchDialog from 'dashboard/components-next/Outbound/ConfirmDeleteTouchDialog.vue';
import OutboundWorkspaceLayout from 'dashboard/components-next/Outbound/OutboundWorkspaceLayout.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import TouchEditorDrawer from 'dashboard/components-next/Outbound/TouchEditorDrawer.vue';
import TouchAnalyticsDialog from 'dashboard/components-next/Outbound/TouchAnalyticsDialog.vue';
import TouchList from 'dashboard/components-next/Outbound/TouchList.vue';

const props = defineProps({
  mode: {
    type: String,
    default: '',
  },
});

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const { accountScopedRoute } = useAccount();
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

const routeMode = computed(() => {
  if (props.mode === 'mass' || props.mode === 'personal') {
    return props.mode;
  }

  return route.query.mode === 'mass' ? 'mass' : 'personal';
});

const currentMode = computed(() => {
  return routeMode.value === 'mass' && canManageMassCampaigns.value
    ? 'mass'
    : 'personal';
});

const isPersonalMode = computed(() => currentMode.value === 'personal');
const selectedTouch = ref(null);

const pageTitle = computed(() => {
  return isPersonalMode.value
    ? t('SIDEBAR.PERSONAL_BROADCASTS')
    : t('SIDEBAR.MASS_BROADCASTS');
});

const pageDescription = computed(() => {
  return isPersonalMode.value
    ? t('OUTBOUND_WORKSPACE.TOUCHES.DESCRIPTION')
    : t('CAMPAIGN.OUTBOUND.SECTIONS.OUTBOUND_DESCRIPTION');
});

const tabs = computed(() => [
  ...[
    {
      id: 'personal',
      label: t('SIDEBAR.PERSONAL_BROADCASTS'),
    },
  ],
  ...(canManageMassCampaigns.value
    ? [
        {
          id: 'mass',
          label: t('SIDEBAR.MASS_BROADCASTS'),
        },
      ]
    : []),
]);

const activeTabIndex = computed(() => {
  const tabIndex = tabs.value.findIndex(tab => tab.id === currentMode.value);
  return tabIndex >= 0 ? tabIndex : 0;
});

const touchEditorSelectionMode = computed(() => {
  return editingTouch.value?.remindable?.id ? 'entity' : 'target';
});

const totalItems = computed(() => {
  return isPersonalMode.value
    ? allTouches.value.length
    : allCampaigns.value.length;
});

const metaCountLabel = computed(() => {
  return isPersonalMode.value
    ? t('OUTBOUND_WORKSPACE.TOUCHES.COUNT', { n: totalItems.value })
    : t('CAMPAIGN.OUTBOUND.COUNT', { n: totalItems.value });
});

const isBusy = computed(() => {
  return isPersonalMode.value
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
  isFetchingTouches.value = true;

  try {
    const { data } = await TouchesAPI.get();
    touches.value = data.payload || [];
  } catch (error) {
    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.LOAD_TOUCHES')
    );
  } finally {
    isFetchingTouches.value = false;
  }
};

const openMassMode = () => {
  const query = { ...route.query };
  delete query.mode;
  router.push(accountScopedRoute('outbound_broadcasts_index', {}, query));
};

const openPersonalMode = () => {
  const query = { ...route.query };
  delete query.mode;
  router.push(
    accountScopedRoute('outbound_broadcasts_personal_index', {}, query)
  );
};

const handleTabChanged = tab => {
  if (tab.id === currentMode.value) return;

  if (tab.id === 'personal') {
    openPersonalMode();
    return;
  }

  openMassMode();
};

const openCreatePersonal = () => {
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
  () => [routeMode.value, canManageMassCampaigns.value],
  ([mode, canManage]) => {
    if (mode === 'mass' && !canManage) {
      openPersonalMode();
    }
  },
  { immediate: true }
);

watch(
  () => isPersonalMode.value,
  isPersonal => {
    if (isPersonal) {
      fetchTouches();
      return;
    }

    if (!canManageMassCampaigns.value) {
      openPersonalMode();
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
        v-if="!isPersonalMode"
        size="sm"
        :label="t('CAMPAIGN.OUTBOUND.ACTIONS.MASS_CAMPAIGN')"
        @click="toggleOutboundCampaignDialog(true)"
      />
      <Button
        v-else
        size="sm"
        :label="t('OUTBOUND_WORKSPACE.TOUCHES.ACTIONS.CREATE')"
        @click="openCreatePersonal"
      />
    </template>

    <template #tabs>
      <TabBar
        :tabs="tabs"
        :initial-active-tab="activeTabIndex"
        @tab-changed="handleTabChanged"
      />
    </template>

    <div
      v-if="isBusy"
      class="flex items-center justify-center py-10 text-n-slate-11"
    >
      <Spinner />
    </div>

    <template v-else-if="isPersonalMode">
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
      <PersonalCampaignEmptyState
        v-else
        :title="$t('OUTBOUND_WORKSPACE.TOUCHES.EMPTY_TITLE')"
        :subtitle="$t('OUTBOUND_WORKSPACE.TOUCHES.EMPTY_SUBTITLE')"
        class="pt-8"
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
