<script setup>
import { computed, nextTick, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  onBeforeRouteLeave,
  onBeforeRouteUpdate,
  useRoute,
  useRouter,
} from 'vue-router';
import Draggable from 'vuedraggable';

import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TagInput from 'dashboard/components-next/taginput/TagInput.vue';
import SelectMenu from 'dashboard/components-next/selectmenu/SelectMenu.vue';
import SchedulingColorPicker from 'dashboard/components-next/Scheduling/SchedulingColorPicker.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { formatCrmErrorMessage } from 'dashboard/stores/crm/shared';
import {
  DEFAULT_STAGE_COLOR,
  STAGE_STANDARD_COLORS,
} from 'dashboard/stores/crm/stageColors';
import {
  isTechnicalStage,
  isTerminalStageOutcome,
  sortStages,
} from './stageOrder';

const referencesStore = useCrmReferencesStore();
const route = useRoute();
const router = useRouter();
const { checkPermissions } = usePolicy();
const { t } = useI18n();

const accountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);
const dealsEnabled = computed(() =>
  isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_DEALS)
);
const canManage = computed(() =>
  checkPermissions(['administrator', 'crm_settings_manage'])
);

const autoCreateSwitchResetKey = ref(0);
const pipelineDrawerOpen = ref(false);
const pipelineDeleteDialogRef = ref(null);
const pipelinePendingDelete = ref(null);
const stageDeleteDialogRef = ref(null);
const stagePendingDelete = ref(null);
const stageDeletionChecking = ref(false);
const unsavedChangesDialogRef = ref(null);
const pipelineSaving = ref(false);
const settingsSaving = ref(false);
const movableStageRows = ref([]);
const lossReasonsEnabled = ref(false);
const closingReasonDraft = ref([]);
const unsortedActiveDraft = ref(true);
const deletedStageIds = ref([]);
const stageDraftBaseline = ref('');
const stageNameDrafts = reactive({});
const pipelineNameDraft = ref('');
const isLeaving = ref(false);
let temporaryStageSequence = 0;
let unsavedDecisionPromise = null;
let resolveUnsavedDecision = null;

const routePipelineId = computed(() => {
  const value = Array.isArray(route.query.pipelineId)
    ? route.query.pipelineId[0]
    : route.query.pipelineId;
  return Number(value) || null;
});

const activePipelines = computed(() =>
  referencesStore.pipelines.filter(pipeline => pipeline.active !== false)
);
const pipelineOptions = computed(() =>
  activePipelines.value.map(pipeline => ({
    label: pipeline.name,
    value: String(pipeline.id),
  }))
);
const selectedPipeline = computed(
  () =>
    activePipelines.value.find(
      pipeline => Number(pipeline.id) === routePipelineId.value
    ) ||
    activePipelines.value.find(pipeline => pipeline.default) ||
    activePipelines.value[0] ||
    null
);
const selectedStages = computed(() =>
  sortStages(selectedPipeline.value?.stages || [])
);
const autoCreateStageOptions = computed(() =>
  sortStages(selectedPipeline.value?.stages || [])
    .filter(
      stage =>
        stage.active !== false &&
        String(stage.outcome).toLowerCase() === 'open' &&
        !isTechnicalStage(stage)
    )
    .map(stage => ({ label: stage.name, value: String(stage.id) }))
);
const selectedAutoCreateStageId = computed(() =>
  String(
    selectedPipeline.value?.stages?.find(
      stage =>
        stage.active !== false &&
        stage.default &&
        String(stage.outcome).toLowerCase() === 'open' &&
        !isTechnicalStage(stage)
    )?.id || ''
  )
);
const selectedAutoCreateStageLabel = computed(
  () =>
    autoCreateStageOptions.value.find(
      option => option.value === selectedAutoCreateStageId.value
    )?.label || t('CRM.SETTINGS.PIPELINES.AUTO_CREATE_DIALOG.STAGE_LABEL')
);
const unsortedStage = computed(() =>
  selectedStages.value.find(isTechnicalStage)
);
const wonStage = computed(() =>
  selectedStages.value.find(
    stage => String(stage.outcome).toLowerCase() === 'won'
  )
);
const lostStage = computed(() =>
  selectedStages.value.find(
    stage => String(stage.outcome).toLowerCase() === 'lost'
  )
);

const pipelineForm = reactive({
  id: null,
  name: '',
});

const pipelineFormDisableConfirm = computed(
  () => !String(pipelineForm.name || '').trim()
);

const normalizedTextValues = values => [
  ...new Set(
    (Array.isArray(values) ? values : [values])
      .map(value => String(value || '').trim())
      .filter(Boolean)
  ),
];
const normalizedClosingReasonDraft = computed(() =>
  normalizedTextValues(closingReasonDraft.value)
);

const stageDraftName = stage =>
  String(stageNameDrafts[stage?.id] ?? stage?.name ?? '').trim();
const buildStageDraftState = () => ({
  closingReasons: lossReasonsEnabled.value
    ? normalizedClosingReasonDraft.value
    : [],
  lostName: lostStage.value ? stageDraftName(lostStage.value) : '',
  regularStages: movableStageRows.value.map((stage, index) => ({
    color: String(stage.color || '').toUpperCase(),
    id: String(stage.id),
    name: stageDraftName(stage),
    position: index + 1,
  })),
  unsortedActive: unsortedStage.value ? unsortedActiveDraft.value : null,
  wonName: wonStage.value ? stageDraftName(wonStage.value) : '',
});
const hasUnsavedStageChanges = computed(
  () =>
    Boolean(stageDraftBaseline.value) &&
    JSON.stringify(buildStageDraftState()) !== stageDraftBaseline.value
);

const formatErrorMessage = error => formatCrmErrorMessage(error, t);

const syncSelectedPipelineRoute = async () => {
  if (!selectedPipeline.value) return;
  if (Number(route.query.pipelineId) === Number(selectedPipeline.value.id))
    return;

  await router.replace({
    query: {
      ...route.query,
      pipelineId: String(selectedPipeline.value.id),
    },
  });
};

const syncSelectedPipelineState = () => {
  movableStageRows.value = selectedStages.value
    .filter(
      stage =>
        !isTechnicalStage(stage) && !isTerminalStageOutcome(stage.outcome)
    )
    .map(stage => ({ ...stage, draft: false }));
  pipelineNameDraft.value = selectedPipeline.value?.name || '';
  selectedStages.value.forEach(stage => {
    stageNameDrafts[stage.id] = stage.name;
  });
  closingReasonDraft.value = [...(lostStage.value?.closingReasonOptions || [])];
  lossReasonsEnabled.value = normalizedClosingReasonDraft.value.length > 0;
  unsortedActiveDraft.value = unsortedStage.value?.active !== false;
  deletedStageIds.value = [];
  stageDraftBaseline.value = JSON.stringify(buildStageDraftState());
};

const loadSettings = async () => {
  await referencesStore.loadPipelines({ include_inactive_stages: true });
  await syncSelectedPipelineRoute();
  syncSelectedPipelineState();
};

watch(routePipelineId, syncSelectedPipelineState);
watch(
  () => referencesStore.pipelines,
  () => {
    if (!settingsSaving.value && !hasUnsavedStageChanges.value) {
      syncSelectedPipelineState();
    }
  },
  { deep: true }
);

const backToDeals = async () => {
  try {
    const navigationFailure = await router.push({
      name: 'crm_deals_index',
      params: { accountId: accountId.value },
      query: { pipelineId: selectedPipeline.value?.id },
    });
    if (navigationFailure) isLeaving.value = false;
  } catch (error) {
    isLeaving.value = false;
    useAlert(formatErrorMessage(error));
  }
};

const selectPipeline = pipelineId =>
  router.replace({
    query: {
      ...route.query,
      pipelineId: String(pipelineId),
    },
  });

const openCreatePipelineDrawer = () => {
  pipelineForm.id = null;
  pipelineForm.name = '';
  pipelineDrawerOpen.value = true;
};

const savePipeline = async () => {
  if (pipelineFormDisableConfirm.value) return;

  pipelineSaving.value = true;
  try {
    const pipeline = await referencesStore.savePipeline({
      id: pipelineForm.id || undefined,
      name: String(pipelineForm.name).trim(),
    });
    pipelineDrawerOpen.value = false;
    await selectPipeline(pipeline.id);
    useAlert(t('CRM.SETTINGS.PIPELINES.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    pipelineSaving.value = false;
  }
};

const saveInlinePipelineName = async () => {
  const name = String(pipelineNameDraft.value || '').trim();
  if (!selectedPipeline.value || name === selectedPipeline.value.name) return;
  if (!name) {
    pipelineNameDraft.value = selectedPipeline.value.name;
    return;
  }

  pipelineSaving.value = true;
  try {
    await referencesStore.savePipeline({
      id: selectedPipeline.value.id,
      name,
    });
    useAlert(t('CRM.SETTINGS.PIPELINES.SUCCESS_SAVE'));
  } catch (error) {
    pipelineNameDraft.value = selectedPipeline.value.name;
    useAlert(formatErrorMessage(error));
  } finally {
    pipelineSaving.value = false;
  }
};

const openDeletePipelineDialog = () => {
  if (!selectedPipeline.value) return;

  pipelinePendingDelete.value = selectedPipeline.value;
  pipelineDeleteDialogRef.value?.open();
};

const deletePipeline = async () => {
  if (!pipelinePendingDelete.value) return;

  pipelineSaving.value = true;
  try {
    await referencesStore.deletePipeline(pipelinePendingDelete.value);
    pipelineDeleteDialogRef.value?.close();
    pipelinePendingDelete.value = null;
    await referencesStore.loadPipelines({ include_inactive_stages: true });
    await syncSelectedPipelineRoute();
    useAlert(t('CRM.SETTINGS.PIPELINES.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    pipelineSaving.value = false;
  }
};

const openLeadForms = () =>
  router.push({
    name: 'lead_forms_index',
    params: { accountId: accountId.value },
  });

const persistPipelineAutoCreate = async (pipeline, value, stageId) => {
  if (!pipeline) return false;

  pipelineSaving.value = true;
  try {
    await referencesStore.savePipeline({
      id: pipeline.id,
      auto_create_deal_on_channel_contact: value,
      auto_create_stage_id: stageId,
    });
    useAlert(t('CRM.SETTINGS.PIPELINES.SUCCESS_SAVE'));
    return true;
  } catch (error) {
    useAlert(formatErrorMessage(error));
    return false;
  } finally {
    pipelineSaving.value = false;
  }
};

const resetPipelineAutoCreateSwitch = () => {
  autoCreateSwitchResetKey.value += 1;
};

const togglePipelineAutoCreate = async value => {
  const pipeline = selectedPipeline.value;
  if (!pipeline) return;

  if (!value) {
    const saved = await persistPipelineAutoCreate(pipeline, false);
    if (!saved) resetPipelineAutoCreateSwitch();
    return;
  }

  const openStages = sortStages(pipeline.stages || []).filter(
    stage =>
      stage.active !== false &&
      String(stage.outcome).toLowerCase() === 'open' &&
      !isTechnicalStage(stage)
  );
  const stageId = String(
    openStages.find(stage => stage.default)?.id || openStages[0]?.id || ''
  );
  const saved = stageId
    ? await persistPipelineAutoCreate(pipeline, true, stageId)
    : false;
  if (!saved) resetPipelineAutoCreateSwitch();
};

const updatePipelineAutoCreateStage = async stageId => {
  const saved = await persistPipelineAutoCreate(
    selectedPipeline.value,
    true,
    stageId
  );
  if (!saved)
    await referencesStore.loadPipelines({ include_inactive_stages: true });
};

const toggleUnsortedStage = active => {
  unsortedActiveDraft.value = active;
};

const saveInlineStageName = stage => {
  stageNameDrafts[stage.id] = stageDraftName(stage);
};

const saveSettings = async () => {
  if (!canManage.value || settingsSaving.value || !selectedPipeline.value)
    return false;
  if (!hasUnsavedStageChanges.value) return true;

  const pipelineId = selectedPipeline.value.id;
  const draftRows = movableStageRows.value.map((stage, index) => ({
    ...stage,
    name: stageDraftName(stage),
    position: index + 1,
  }));
  const deletedIds = [...deletedStageIds.value];
  const terminalStages = [wonStage.value, lostStage.value].filter(Boolean);
  const originalUnsortedStage = unsortedStage.value;
  const closingReasons = lossReasonsEnabled.value
    ? normalizedClosingReasonDraft.value
    : [];
  const hasBlankStageName = [...draftRows, ...terminalStages].some(
    stage => !stageDraftName(stage)
  );
  if (hasBlankStageName) {
    useAlert(t('CRM.ERRORS.VALIDATION_ERROR'));
    return false;
  }

  settingsSaving.value = true;
  try {
    await referencesStore.batchUpdateStages(pipelineId, {
      deleted_stage_ids: deletedIds,
      stages: draftRows.map(stage => ({
        id: stage.draft ? undefined : stage.id,
        name: stage.name,
        color: stage.color,
        active: stage.draft ? true : stage.active !== false,
      })),
      technical_stage: originalUnsortedStage
        ? {
            id: originalUnsortedStage.id,
            active: unsortedActiveDraft.value,
          }
        : undefined,
      terminal_stages: terminalStages.map(stage => ({
        id: stage.id,
        name: stageDraftName(stage),
        closing_reason_options:
          stage.id === lostStage.value?.id
            ? closingReasons
            : normalizedTextValues(stage.closingReasonOptions || []),
      })),
    });
    await referencesStore.loadPipelines({ include_inactive_stages: true });
    syncSelectedPipelineState();
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_SAVE'));
    return true;
  } catch (error) {
    useAlert(formatErrorMessage(error));
    return false;
  } finally {
    settingsSaving.value = false;
  }
};

const settleUnsavedDecision = decision => {
  const resolve = resolveUnsavedDecision;
  resolveUnsavedDecision = null;
  unsavedDecisionPromise = null;
  unsavedChangesDialogRef.value?.close();
  resolve?.(decision);
};

const requestUnsavedDecision = () => {
  if (unsavedDecisionPromise) return unsavedDecisionPromise;

  unsavedDecisionPromise = new Promise(resolve => {
    resolveUnsavedDecision = resolve;
    unsavedChangesDialogRef.value?.open();
  });
  return unsavedDecisionPromise;
};

const resolveUnsavedChanges = async () => {
  if (!hasUnsavedStageChanges.value) return true;

  const decision = await requestUnsavedDecision();
  if (decision === 'stay') return false;
  if (decision === 'save') return saveSettings();

  syncSelectedPipelineState();
  return true;
};

const prepareForRouteLeave = async () => {
  if (isLeaving.value) return true;

  const canLeave = await resolveUnsavedChanges();
  if (!canLeave) return false;

  isLeaving.value = true;
  pipelineDrawerOpen.value = false;
  await nextTick();
  return true;
};

onBeforeRouteLeave(prepareForRouteLeave);
onBeforeRouteUpdate((to, from) => {
  const nextPipelineId = Array.isArray(to.query.pipelineId)
    ? to.query.pipelineId[0]
    : to.query.pipelineId;
  const currentPipelineId = Array.isArray(from.query.pipelineId)
    ? from.query.pipelineId[0]
    : from.query.pipelineId;

  return String(nextPipelineId || '') === String(currentPipelineId || '')
    ? true
    : resolveUnsavedChanges();
});

const toggleInlineClosingReasons = value => {
  lossReasonsEnabled.value = value;
};

const randomStageColor = () => {
  const index = Math.floor(Math.random() * STAGE_STANDARD_COLORS.length);
  return STAGE_STANDARD_COLORS[index] || DEFAULT_STAGE_COLOR;
};

const focusStageName = async stageId => {
  await nextTick();
  document.querySelector(`[data-stage-name-id="${stageId}"]`)?.focus();
};

const createStageAt = async insertIndex => {
  if (!canManage.value || !selectedPipeline.value) return;

  const targetIndex = Math.max(
    0,
    Math.min(Number(insertIndex) || 0, movableStageRows.value.length)
  );
  temporaryStageSequence += 1;
  const temporaryId = `draft-stage-${temporaryStageSequence}`;
  const newStageName = t('CRM.SETTINGS.STAGES.NEW_NAME');
  const draftStage = {
    active: true,
    color: randomStageColor(),
    draft: true,
    id: temporaryId,
    name: newStageName,
    outcome: 'open',
    pipelineId: selectedPipeline.value.id,
    position: targetIndex + 1,
  };

  movableStageRows.value.splice(targetIndex, 0, draftStage);
  stageNameDrafts[temporaryId] = newStageName;
  await focusStageName(temporaryId);
};

const saveInlineStageColor = (stage, color) => {
  if (!color || color.toUpperCase() === stage.color?.toUpperCase()) return;
  stage.color = color;
};

const openDeleteStageDialog = async stage => {
  if (!stage || isTerminalStageOutcome(stage.outcome)) return;

  stageDeletionChecking.value = true;
  try {
    if (!stage.draft) await referencesStore.checkStageDeletion(stage.id);
    stagePendingDelete.value = {
      draft: stage.draft,
      id: stage.id,
      name: stageDraftName(stage),
    };
    stageDeleteDialogRef.value?.open();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    stageDeletionChecking.value = false;
  }
};

const deleteStage = () => {
  if (!stagePendingDelete.value) return;

  const stage = stagePendingDelete.value;
  movableStageRows.value = movableStageRows.value.filter(
    candidate => String(candidate.id) !== String(stage.id)
  );
  delete stageNameDrafts[stage.id];
  if (!stage.draft && !deletedStageIds.value.includes(stage.id)) {
    deletedStageIds.value.push(stage.id);
  }
  stageDeleteDialogRef.value?.close();
  stagePendingDelete.value = null;
};

const stageCardStyle = stage => ({
  borderTopColor: stage.color || DEFAULT_STAGE_COLOR,
});
const pipelineAutoCreateEnabled = computed(() =>
  Boolean(
    selectedPipeline.value?.autoCreateDealOnChannelContact ??
      selectedPipeline.value?.auto_create_deal_on_channel_contact
  )
);
const pipelineAutoCreateSwitchKey = computed(
  () =>
    `${selectedPipeline.value?.id}-${pipelineAutoCreateEnabled.value}-${autoCreateSwitchResetKey.value}`
);
const handleRouteAction = async () => {
  if (route.query.action !== 'create-stage' || !canManage.value) return;

  await createStageAt(movableStageRows.value.length);
  const query = { ...route.query };
  delete query.action;
  await router.replace({ query });
};

onMounted(async () => {
  if (!dealsEnabled.value) return;

  await loadSettings();
  await handleRouteAction();
});
</script>

<template>
  <SettingsLayout
    :is-loading="referencesStore.ui.isLoadingPipelines"
    :loading-message="$t('CRM.SETTINGS.LOADING')"
  >
    <template #loading>
      <div class="flex justify-center py-16">
        <Spinner class="!h-8 !w-8" />
      </div>
    </template>

    <template #body>
      <div
        v-if="dealsEnabled && !isLeaving"
        class="flex h-full min-h-0 flex-col"
      >
        <SchedulingErrorState
          v-if="referencesStore.ui.error"
          :title="$t('CRM.ERRORS.LOAD_TITLE')"
          :description="formatErrorMessage(referencesStore.ui.error)"
          @retry="loadSettings"
        />

        <template v-else-if="selectedPipeline">
          <SchedulingPageHeader
            class="relative z-20 shrink-0 !bg-n-surface-1"
            :title="selectedPipeline.name"
          >
            <template #title>
              <div class="flex min-w-0 items-center gap-1">
                <input
                  v-model="pipelineNameDraft"
                  data-testid="pipeline-name-input"
                  type="text"
                  class="min-w-48 max-w-[28rem] rounded-md border border-transparent bg-transparent px-1 py-1 text-lg font-semibold text-n-slate-12 outline-none transition hover:border-n-weak focus:border-n-brand focus:bg-n-surface-1"
                  :disabled="!canManage || pipelineSaving"
                  @blur="saveInlinePipelineName"
                  @keydown.enter="$event.currentTarget.blur()"
                />
                <SelectMenu
                  :model-value="String(selectedPipeline.id)"
                  :options="pipelineOptions"
                  label=""
                  :action-label="
                    canManage ? $t('CRM.SETTINGS.PIPELINES.ADD') : ''
                  "
                  size="sm"
                  variant="ghost"
                  trigger-class="!max-w-8 !px-1 hover:!bg-transparent"
                  :trigger-aria-label="selectedPipeline.name"
                  :highlight-trigger="false"
                  sub-menu-align="start"
                  sub-menu-position="bottom"
                  @update:model-value="selectPipeline"
                  @action="openCreatePipelineDrawer"
                />
              </div>
            </template>
            <template #actions>
              <Button
                v-if="canManage"
                size="sm"
                color="ruby"
                variant="ghost"
                icon="i-lucide-trash-2"
                :aria-label="$t('CRM.SETTINGS.PIPELINES.DELETE')"
                :title="$t('CRM.SETTINGS.PIPELINES.DELETE')"
                @click="openDeletePipelineDialog"
              />
              <Button
                color="slate"
                variant="ghost"
                :label="$t('CRM.SETTINGS.PIPELINES.BACK_TO_DEALS')"
                :aria-label="$t('CRM.SETTINGS.PIPELINES.BACK_TO_DEALS')"
                :title="$t('CRM.SETTINGS.PIPELINES.BACK_TO_DEALS')"
                @click="backToDeals"
              />
              <Button
                data-testid="save-settings-button"
                :label="$t('CRM.GENERAL.SAVE')"
                :is-loading="settingsSaving"
                :disabled="
                  !canManage || settingsSaving || !hasUnsavedStageChanges
                "
                @click="saveSettings"
              />
            </template>
          </SchedulingPageHeader>

          <div class="min-h-0 flex-1 overflow-auto">
            <div
              class="grid min-h-[34rem] min-w-max grid-cols-[18rem_max-content] gap-5 px-5 pb-5"
            >
              <aside
                class="h-fit overflow-hidden rounded-2xl border border-n-weak bg-n-solid-2"
              >
                <div class="border-b border-n-weak px-5 py-4">
                  <div
                    class="flex items-center gap-2 text-sm font-semibold text-n-slate-12"
                  >
                    <span class="i-lucide-plug-zap size-4 text-n-brand" />
                    {{ $t('CRM.SETTINGS.PIPELINES.SOURCES_TITLE') }}
                  </div>
                </div>

                <div class="grid divide-y divide-n-weak">
                  <div class="grid gap-3 px-5 py-4">
                    <div class="flex items-center justify-between gap-3">
                      <div
                        class="flex items-center gap-2 text-sm font-medium text-n-slate-12"
                      >
                        <span class="i-lucide-zap size-4 text-n-brand" />
                        {{ $t('CRM.SETTINGS.PIPELINES.FORM.AUTO_CREATE') }}
                      </div>
                      <Switch
                        :key="pipelineAutoCreateSwitchKey"
                        :model-value="pipelineAutoCreateEnabled"
                        :disabled="!canManage || pipelineSaving"
                        @update:model-value="togglePipelineAutoCreate"
                      />
                    </div>
                    <p class="mb-0 text-xs leading-5 text-n-slate-10">
                      {{
                        $t(
                          'CRM.SETTINGS.PIPELINES.FORM.AUTO_CREATE_DEAL_ON_CHANNEL_CONTACT_HELP'
                        )
                      }}
                    </p>
                    <div v-if="pipelineAutoCreateEnabled" class="grid gap-2">
                      <span class="text-xs font-medium text-n-slate-11">
                        {{
                          $t(
                            'CRM.SETTINGS.PIPELINES.AUTO_CREATE_DIALOG.STAGE_LABEL'
                          )
                        }}
                      </span>
                      <SelectMenu
                        v-if="canManage && !pipelineSaving"
                        data-testid="auto-create-stage-select"
                        :model-value="selectedAutoCreateStageId"
                        :options="autoCreateStageOptions"
                        :label="selectedAutoCreateStageLabel"
                        class="w-full"
                        sub-menu-align="start"
                        sub-menu-position="bottom"
                        @update:model-value="updatePipelineAutoCreateStage"
                      />
                      <span v-else class="text-sm font-medium text-n-slate-12">
                        {{ selectedAutoCreateStageLabel }}
                      </span>
                      <p
                        v-if="autoCreateStageOptions.length === 0"
                        class="mb-0 text-xs leading-5 text-n-ruby-10"
                      >
                        {{
                          $t(
                            'CRM.SETTINGS.PIPELINES.AUTO_CREATE_DIALOG.NO_STAGES'
                          )
                        }}
                      </p>
                    </div>
                  </div>

                  <div class="grid gap-3 px-5 py-4">
                    <div class="flex items-center justify-between gap-3">
                      <div
                        class="flex items-center gap-2 text-sm font-medium text-n-slate-12"
                      >
                        <span class="i-lucide-inbox size-4 text-n-slate-10" />
                        {{ $t('CRM.SETTINGS.STAGES.SYSTEM.UNSORTED') }}
                      </div>
                      <Switch
                        :model-value="unsortedActiveDraft"
                        :disabled="
                          !canManage || !unsortedStage || settingsSaving
                        "
                        @update:model-value="toggleUnsortedStage"
                      />
                    </div>
                    <p class="mb-0 text-xs leading-5 text-n-slate-10">
                      {{ $t('CRM.SETTINGS.PIPELINES.UNSORTED_HELP') }}
                    </p>
                  </div>

                  <button
                    type="button"
                    class="group grid gap-3 px-5 py-4 text-left transition-colors hover:bg-n-alpha-black2"
                    @click="openLeadForms"
                  >
                    <div class="flex items-center justify-between gap-3">
                      <div
                        class="flex items-center gap-2 text-sm font-medium text-n-slate-12"
                      >
                        <span class="i-lucide-file-input size-4 text-n-brand" />
                        {{ $t('CRM.SETTINGS.PIPELINES.LEAD_FORMS_TITLE') }}
                      </div>
                      <span
                        class="i-lucide-arrow-up-right size-4 text-n-slate-9 transition-colors group-hover:text-n-brand"
                      />
                    </div>
                    <p class="mb-0 text-xs leading-5 text-n-slate-10">
                      {{ $t('CRM.SETTINGS.PIPELINES.LEAD_FORMS_HELP') }}
                    </p>
                  </button>
                </div>
              </aside>

              <section class="w-max">
                <div class="py-1">
                  <div class="flex min-w-max items-stretch">
                    <Draggable
                      v-model="movableStageRows"
                      item-key="id"
                      handle=".stage-drag-handle"
                      animation="200"
                      ghost-class="pipeline-ghost"
                      class="flex items-stretch"
                      :disabled="!canManage || settingsSaving"
                    >
                      <template #item="{ element: stage, index }">
                        <div class="flex shrink-0 items-stretch">
                          <button
                            v-if="canManage"
                            type="button"
                            data-modal-safe-interaction
                            :data-testid="`create-stage-at-${index}`"
                            class="stage-create-button group relative flex w-8 shrink-0 items-center justify-center"
                            :aria-label="$t('CRM.SETTINGS.STAGES.CREATE_TITLE')"
                            :title="$t('CRM.SETTINGS.STAGES.CREATE_TITLE')"
                            :disabled="settingsSaving"
                            @pointerdown.stop
                            @click.prevent.stop="createStageAt(index)"
                          >
                            <span
                              class="absolute inset-x-0 h-px bg-n-weak transition-colors group-hover:bg-n-brand/50"
                            />
                            <span
                              class="relative flex size-7 items-center justify-center rounded-full border border-n-strong bg-n-solid-2 text-n-slate-10 shadow-sm ring-4 ring-n-surface-1 transition group-hover:border-n-brand group-hover:text-n-brand"
                            >
                              <span class="i-lucide-plus size-4" />
                            </span>
                          </button>

                          <article
                            class="flex min-h-44 w-[15rem] shrink-0 flex-col rounded-xl border-t-4 bg-n-slate-2 shadow-sm"
                            :data-stage-id="stage.id"
                            :data-draft-stage="stage.draft ? 'true' : undefined"
                            :style="stageCardStyle(stage)"
                          >
                            <div class="flex flex-col px-3 pt-1">
                              <button
                                v-if="canManage"
                                type="button"
                                class="stage-drag-handle flex h-7 w-full cursor-grab items-center justify-center rounded-md text-n-slate-9 hover:text-n-slate-12"
                                :title="$t('CRM.SETTINGS.STAGES.REORDER')"
                              >
                                <span
                                  class="i-lucide-grip-vertical size-5 rotate-90"
                                />
                              </button>
                              <span v-else class="pt-2 text-xs text-n-slate-9">
                                {{ index + 1 }}
                              </span>
                              <input
                                v-model="stageNameDrafts[stage.id]"
                                type="text"
                                :data-stage-name-id="stage.id"
                                :placeholder="
                                  $t('CRM.SETTINGS.STAGES.FORM.NAME')
                                "
                                class="w-full rounded-md border border-transparent bg-transparent px-1 py-1 text-sm font-semibold text-n-slate-12 outline-none transition hover:border-n-weak focus:border-n-brand focus:bg-n-surface-1"
                                :disabled="!canManage || settingsSaving"
                                @blur="saveInlineStageName(stage)"
                                @keydown.enter="$event.currentTarget.blur()"
                              />
                            </div>
                            <div
                              class="mt-auto flex items-center justify-between gap-2 px-3 pb-3 pt-2"
                            >
                              <SchedulingColorPicker
                                compact
                                :model-value="stage.color"
                                :palette="STAGE_STANDARD_COLORS"
                                :trigger-label="
                                  $t('CRM.SETTINGS.STAGES.FORM.COLOR')
                                "
                                :disabled="!canManage || settingsSaving"
                                @update:model-value="
                                  saveInlineStageColor(stage, $event)
                                "
                              />
                              <Button
                                v-if="canManage"
                                size="xs"
                                color="ruby"
                                variant="ghost"
                                icon="i-lucide-trash-2"
                                :aria-label="$t('CRM.SETTINGS.STAGES.DELETE')"
                                :title="$t('CRM.SETTINGS.STAGES.DELETE')"
                                :disabled="
                                  settingsSaving || stageDeletionChecking
                                "
                                @click="openDeleteStageDialog(stage)"
                              />
                            </div>
                          </article>
                        </div>
                      </template>
                    </Draggable>

                    <button
                      v-if="canManage"
                      type="button"
                      data-testid="create-stage-button"
                      data-modal-safe-interaction
                      class="stage-create-button group relative flex w-8 shrink-0 items-center justify-center"
                      :aria-label="$t('CRM.SETTINGS.STAGES.CREATE_TITLE')"
                      :title="$t('CRM.SETTINGS.STAGES.CREATE_TITLE')"
                      :disabled="settingsSaving"
                      @pointerdown.stop
                      @click.prevent.stop="
                        createStageAt(movableStageRows.length)
                      "
                    >
                      <span
                        class="absolute inset-x-0 h-px bg-n-weak transition-colors group-hover:bg-n-brand/50"
                      />
                      <span
                        class="relative flex size-7 items-center justify-center rounded-full border border-n-strong bg-n-solid-2 text-n-slate-10 shadow-sm ring-4 ring-n-surface-1 transition group-hover:border-n-brand group-hover:text-n-brand"
                      >
                        <span class="i-lucide-plus size-4" />
                      </span>
                    </button>

                    <article
                      v-if="wonStage"
                      class="flex min-h-44 w-[15rem] shrink-0 flex-col rounded-xl border-t-4 bg-n-slate-2 shadow-sm"
                      :style="stageCardStyle(wonStage)"
                    >
                      <div class="grid gap-3 p-4">
                        <input
                          v-model="stageNameDrafts[wonStage.id]"
                          type="text"
                          class="w-full rounded-md border border-transparent bg-transparent px-1 py-1 text-sm font-semibold text-n-slate-12 outline-none transition hover:border-n-weak focus:border-n-brand focus:bg-n-surface-1"
                          :disabled="!canManage || settingsSaving"
                          @blur="saveInlineStageName(wonStage)"
                          @keydown.enter="$event.currentTarget.blur()"
                        />
                        <span class="text-xs text-n-slate-9">
                          {{ $t('CRM.SETTINGS.STAGES.WON_HELP') }}
                        </span>
                      </div>
                    </article>

                    <div class="w-8 shrink-0" />

                    <article
                      v-if="lostStage"
                      class="flex min-h-44 w-[15rem] shrink-0 flex-col rounded-xl border-t-4 bg-n-slate-2 shadow-sm"
                      :style="stageCardStyle(lostStage)"
                    >
                      <div class="grid gap-3 p-4">
                        <input
                          v-model="stageNameDrafts[lostStage.id]"
                          type="text"
                          class="w-full rounded-md border border-transparent bg-transparent px-1 py-1 text-sm font-semibold text-n-slate-12 outline-none transition hover:border-n-weak focus:border-n-brand focus:bg-n-surface-1"
                          :disabled="!canManage || settingsSaving"
                          @blur="saveInlineStageName(lostStage)"
                          @keydown.enter="$event.currentTarget.blur()"
                        />
                        <div class="flex items-center justify-between gap-3">
                          <span class="text-xs font-medium text-n-slate-11">
                            {{
                              $t(
                                'CRM.SETTINGS.STAGES.FORM.LOSS_REASONS_ENABLED'
                              )
                            }}
                          </span>
                          <Switch
                            :model-value="lossReasonsEnabled"
                            :disabled="!canManage || settingsSaving"
                            @update:model-value="toggleInlineClosingReasons"
                          />
                        </div>
                        <template v-if="lossReasonsEnabled">
                          <TagInput
                            v-model="closingReasonDraft"
                            class="rounded-lg bg-n-surface-1 p-2 outline outline-1 outline-n-weak"
                            allow-create
                            :disabled="!canManage || settingsSaving"
                            :auto-open-dropdown="false"
                            :placeholder="
                              $t(
                                'CRM.SETTINGS.STAGES.FORM.CLOSING_REASONS_PLACEHOLDER'
                              )
                            "
                          />
                        </template>
                      </div>
                    </article>
                  </div>
                </div>
              </section>
            </div>
          </div>
        </template>
      </div>
    </template>

    <SchedulingDrawer
      v-model="pipelineDrawerOpen"
      placement="center"
      width="sm"
      :title="
        pipelineForm.id
          ? $t('CRM.SETTINGS.PIPELINES.EDIT_TITLE')
          : $t('CRM.SETTINGS.PIPELINES.CREATE_TITLE')
      "
      :confirm-label="$t('CRM.GENERAL.SAVE')"
      :is-loading="pipelineSaving"
      :disable-confirm="pipelineFormDisableConfirm"
      @confirm="savePipeline"
    >
      <div class="grid gap-2">
        <Input
          autofocus
          :label="$t('CRM.SETTINGS.PIPELINES.FORM.NAME')"
          :model-value="pipelineForm.name"
          @update:model-value="pipelineForm.name = $event"
          @enter="savePipeline"
        />
        <p v-if="!pipelineForm.id" class="mb-0 text-xs text-n-slate-10">
          {{ $t('CRM.SETTINGS.PIPELINES.NEW_PIPELINE_HELP') }}
        </p>
      </div>
    </SchedulingDrawer>

    <Dialog
      ref="pipelineDeleteDialogRef"
      width="md"
      type="alert"
      :title="$t('CRM.SETTINGS.PIPELINES.DELETE_TITLE')"
      :description="
        $t('CRM.SETTINGS.PIPELINES.DELETE_DESCRIPTION', {
          name: pipelinePendingDelete?.name || '',
        })
      "
      :confirm-button-label="$t('CRM.SETTINGS.PIPELINES.DELETE_CONFIRM')"
      :is-loading="pipelineSaving"
      @close="pipelinePendingDelete = null"
      @confirm="deletePipeline"
    />

    <Dialog
      ref="stageDeleteDialogRef"
      width="md"
      type="alert"
      :title="$t('CRM.SETTINGS.STAGES.DELETE_TITLE')"
      :description="
        $t('CRM.SETTINGS.STAGES.DELETE_DESCRIPTION', {
          name: stagePendingDelete?.name || '',
        })
      "
      :confirm-button-label="$t('CRM.SETTINGS.STAGES.DELETE_CONFIRM')"
      :is-loading="settingsSaving"
      @close="stagePendingDelete = null"
      @confirm="deleteStage"
    />

    <Dialog
      ref="unsavedChangesDialogRef"
      width="md"
      :title="$t('CRM.SETTINGS.STAGES.UNSAVED.TITLE')"
      :description="$t('CRM.SETTINGS.STAGES.UNSAVED.DESCRIPTION')"
      :show-cancel-button="false"
      :show-confirm-button="false"
      @close="settleUnsavedDecision('stay')"
    >
      <template #footer>
        <div class="flex w-full flex-col gap-2 sm:flex-row">
          <Button
            class="w-full"
            color="slate"
            variant="faded"
            :label="$t('CRM.SETTINGS.STAGES.UNSAVED.STAY')"
            @click="settleUnsavedDecision('stay')"
          />
          <Button
            class="w-full"
            color="slate"
            variant="faded"
            :label="$t('CRM.SETTINGS.STAGES.UNSAVED.DISCARD')"
            @click="settleUnsavedDecision('discard')"
          />
          <Button
            class="w-full"
            color="blue"
            :label="$t('CRM.SETTINGS.STAGES.UNSAVED.SAVE')"
            @click="settleUnsavedDecision('save')"
          />
        </div>
      </template>
    </Dialog>
  </SettingsLayout>
</template>
