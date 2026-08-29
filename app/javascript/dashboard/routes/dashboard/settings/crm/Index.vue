<script setup>
import { computed, nextTick, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { onBeforeRouteLeave, useRoute, useRouter } from 'vue-router';
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
  getUnavailableStageColors,
  pickStageColor,
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

const stageDrawerOpen = ref(false);
const stageDeleteDialogRef = ref(null);
const stagePendingDelete = ref(null);
const stageOrderSaving = ref(false);
const pipelineSaving = ref(false);
const settingsSaving = ref(false);
const movableStageRows = ref([]);
const lossReasonsEnabled = ref(false);
const closingReasonDraft = ref([]);
const stageNameDrafts = reactive({});
const pendingInsertIndex = ref(null);
const isLeaving = ref(false);

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

const stageForm = reactive({
  active: true,
  closingReasonOptions: [],
  color: DEFAULT_STAGE_COLOR,
  default: false,
  id: null,
  name: '',
  outcome: 'open',
  pipelineId: '',
  transitionReasonOptions: [],
  transitionReasonRequired: false,
});

const stageFormIsTerminal = computed(() =>
  Boolean(stageForm.id && isTerminalStageOutcome(stageForm.outcome))
);
const stageFormIsLost = computed(
  () => stageForm.id && String(stageForm.outcome).toLowerCase() === 'lost'
);
const normalizedTextValues = values => [
  ...new Set(
    (Array.isArray(values) ? values : [values])
      .map(value => String(value || '').trim())
      .filter(Boolean)
  ),
];
const normalizedStageFormClosingReasons = computed(() =>
  normalizedTextValues(stageForm.closingReasonOptions)
);
const normalizedStageFormTransitionReasons = computed(() =>
  normalizedTextValues(stageForm.transitionReasonOptions)
);
const normalizedClosingReasonDraft = computed(() =>
  normalizedTextValues(closingReasonDraft.value)
);
const stageFormDisableConfirm = computed(
  () =>
    !String(stageForm.name || '').trim() ||
    (!stageFormIsTerminal.value && !String(stageForm.color || '').trim()) ||
    (!stageFormIsTerminal.value &&
      stageForm.transitionReasonRequired &&
      normalizedStageFormTransitionReasons.value.length === 0)
);
const unavailableStageColors = computed(() =>
  getUnavailableStageColors(selectedPipeline.value?.stages || [], stageForm.id)
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
  movableStageRows.value = selectedStages.value.filter(
    stage => !isTechnicalStage(stage) && !isTerminalStageOutcome(stage.outcome)
  );
  selectedStages.value.forEach(stage => {
    stageNameDrafts[stage.id] = stage.name;
  });
  closingReasonDraft.value = [...(lostStage.value?.closingReasonOptions || [])];
  lossReasonsEnabled.value = normalizedClosingReasonDraft.value.length > 0;
};

const loadSettings = async () => {
  await referencesStore.loadPipelines({ include_inactive_stages: true });
  await syncSelectedPipelineRoute();
  syncSelectedPipelineState();
};

watch(
  () => [routePipelineId.value, referencesStore.pipelines],
  () => syncSelectedPipelineState(),
  { deep: true }
);

const prepareForRouteLeave = async () => {
  if (isLeaving.value) return;

  isLeaving.value = true;
  stageDrawerOpen.value = false;
  await nextTick();
};

onBeforeRouteLeave(prepareForRouteLeave);

const backToDeals = async () => {
  await prepareForRouteLeave();

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

const openLeadForms = () =>
  router.push({
    name: 'lead_forms_index',
    params: { accountId: accountId.value },
  });

const togglePipelineAutoCreate = async value => {
  const pipeline = selectedPipeline.value;
  if (!pipeline) return;

  pipelineSaving.value = true;
  try {
    await referencesStore.savePipeline({
      id: pipeline.id,
      auto_create_deal_on_channel_contact: value,
    });
    useAlert(t('CRM.SETTINGS.PIPELINES.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    pipelineSaving.value = false;
  }
};

const toggleUnsortedStage = async active => {
  if (!unsortedStage.value) return;

  try {
    await referencesStore.saveStage({
      id: unsortedStage.value.id,
      active,
      color: unsortedStage.value.color,
    });
    await referencesStore.loadPipelines({ include_inactive_stages: true });
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const persistStageOrder = async event => {
  if (!selectedPipeline.value || stageOrderSaving.value) return;
  if (event.oldIndex === event.newIndex) return;

  stageOrderSaving.value = true;
  try {
    await referencesStore.reorderStages(
      selectedPipeline.value.id,
      movableStageRows.value.map(stage => stage.id)
    );
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_REORDER'));
  } catch (error) {
    syncSelectedPipelineState();
    useAlert(formatErrorMessage(error));
  } finally {
    stageOrderSaving.value = false;
  }
};

const saveInlineStageName = async stage => {
  const name = String(stageNameDrafts[stage.id] || '').trim();
  if (!name || name === stage.name) {
    stageNameDrafts[stage.id] = stage.name;
    return;
  }

  try {
    await referencesStore.saveStage({ id: stage.id, name });
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_SAVE'));
  } catch (error) {
    stageNameDrafts[stage.id] = stage.name;
    useAlert(formatErrorMessage(error));
  }
};

const saveInlineClosingReasons = async () => {
  if (!canManage.value || !lostStage.value) return;

  try {
    await referencesStore.saveStage({
      id: lostStage.value.id,
      name: String(
        stageNameDrafts[lostStage.value.id] || lostStage.value.name
      ).trim(),
      closing_reason_options: lossReasonsEnabled.value
        ? normalizedClosingReasonDraft.value
        : [],
      closing_reason_required: false,
    });
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_SAVE'));
  } catch (error) {
    syncSelectedPipelineState();
    useAlert(formatErrorMessage(error));
  }
};

const saveSettings = async () => {
  if (!canManage.value || settingsSaving.value) return;

  const lost = lostStage.value;
  const closingReasons = lossReasonsEnabled.value
    ? normalizedClosingReasonDraft.value
    : [];
  const currentClosingReasons = normalizedTextValues(
    lost?.closingReasonOptions || []
  );

  const payloads = selectedStages.value
    .map(stage => {
      const payload = { id: stage.id };
      const name = String(stageNameDrafts[stage.id] || '').trim();
      if (name && name !== stage.name) payload.name = name;

      if (
        stage.id === lost?.id &&
        JSON.stringify(closingReasons) !== JSON.stringify(currentClosingReasons)
      ) {
        payload.closing_reason_options = closingReasons;
        payload.closing_reason_required = false;
      }

      return Object.keys(payload).length > 1 ? payload : null;
    })
    .filter(Boolean);

  settingsSaving.value = true;
  try {
    await Promise.all(
      payloads.map(payload => referencesStore.saveStage(payload))
    );
    if (payloads.length) {
      await referencesStore.loadPipelines({ include_inactive_stages: true });
    }
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_SAVE'));
  } catch (error) {
    syncSelectedPipelineState();
    useAlert(formatErrorMessage(error));
  } finally {
    settingsSaving.value = false;
  }
};

const toggleInlineClosingReasons = value => {
  lossReasonsEnabled.value = value;
  if (!value) saveInlineClosingReasons();
};

const resetStageForm = () => {
  Object.assign(stageForm, {
    active: true,
    closingReasonOptions: [],
    color: pickStageColor(selectedPipeline.value?.stages || []),
    default: false,
    id: null,
    name: '',
    outcome: 'open',
    pipelineId: selectedPipeline.value?.id || '',
    transitionReasonOptions: [],
    transitionReasonRequired: false,
  });
  lossReasonsEnabled.value = false;
};

const openStageDrawer = (stage, insertIndex = null) => {
  pendingInsertIndex.value = stage ? null : insertIndex;
  resetStageForm();
  if (stage) {
    Object.assign(stageForm, {
      active: stage.active !== false,
      closingReasonOptions: [...(stage.closingReasonOptions || [])],
      color: stage.color || DEFAULT_STAGE_COLOR,
      default: Boolean(stage.default),
      id: stage.id,
      name: stage.name,
      outcome: stage.outcome,
      pipelineId: stage.pipelineId || selectedPipeline.value?.id,
      transitionReasonOptions: [...(stage.transitionReasonOptions || [])],
      transitionReasonRequired: Boolean(stage.transitionReasonRequired),
    });
    lossReasonsEnabled.value =
      normalizedTextValues(stage.closingReasonOptions).length > 0;
  }
  stageDrawerOpen.value = true;
};

const saveStage = async () => {
  if (stageFormDisableConfirm.value) return;

  const payload = stageFormIsTerminal.value
    ? {
        id: stageForm.id,
        name: String(stageForm.name).trim(),
        closing_reason_options:
          stageFormIsLost.value && lossReasonsEnabled.value
            ? normalizedStageFormClosingReasons.value
            : [],
        closing_reason_required: false,
      }
    : {
        id: stageForm.id || undefined,
        pipelineId: stageForm.pipelineId,
        name: String(stageForm.name).trim(),
        color: stageForm.color,
        active: stageForm.active,
        default: stageForm.default,
        transition_reason_options: normalizedStageFormTransitionReasons.value,
        transition_reason_required: stageForm.transitionReasonRequired,
      };

  const stageOrderBeforeCreate = movableStageRows.value.map(stage => stage.id);
  let createdStage = null;

  try {
    const savedStage = await referencesStore.saveStage(payload);
    if (!payload.id) createdStage = savedStage;
    if (!payload.id && pendingInsertIndex.value !== null) {
      stageOrderBeforeCreate.splice(pendingInsertIndex.value, 0, savedStage.id);
      await referencesStore.reorderStages(
        selectedPipeline.value.id,
        stageOrderBeforeCreate
      );
    }
    await referencesStore.loadPipelines({ include_inactive_stages: true });
    stageDrawerOpen.value = false;
    pendingInsertIndex.value = null;
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_SAVE'));
  } catch (error) {
    if (createdStage) {
      try {
        await referencesStore.loadPipelines({ include_inactive_stages: true });
      } catch {
        // The created stage is already present in Pinia from saveStage.
      }
      stageDrawerOpen.value = false;
      pendingInsertIndex.value = null;
    }
    useAlert(formatErrorMessage(error));
  }
};

const openDeleteStageDialog = () => {
  if (!stageForm.id || stageFormIsTerminal.value) return;
  stagePendingDelete.value = { id: stageForm.id, name: stageForm.name };
  stageDeleteDialogRef.value?.open();
};

const deleteStage = async () => {
  if (!stagePendingDelete.value) return;

  try {
    await referencesStore.deleteStage(stagePendingDelete.value);
    stageDeleteDialogRef.value?.close();
    stageDrawerOpen.value = false;
    stagePendingDelete.value = null;
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
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
const stageColorDisabled = color =>
  unavailableStageColors.value.has(String(color || '').toUpperCase());

const updateStageActive = active => {
  stageForm.active = active;
  if (!active) stageForm.default = false;
};

const handleRouteAction = async () => {
  if (route.query.action !== 'create-stage' || !canManage.value) return;

  openStageDrawer();
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
              <SelectMenu
                :model-value="String(selectedPipeline.id)"
                :options="pipelineOptions"
                :label="selectedPipeline.name"
                size="lg"
                variant="ghost"
                trigger-class="!max-w-[28rem] !px-0 !text-lg !font-semibold !text-n-slate-12 hover:!bg-transparent"
                :highlight-trigger="false"
                sub-menu-align="start"
                sub-menu-position="bottom"
                @update:model-value="selectPipeline"
              />
            </template>
            <template #actions>
              <Button
                color="slate"
                variant="ghost"
                :label="$t('CRM.SETTINGS.PIPELINES.BACK_TO_DEALS')"
                :aria-label="$t('CRM.SETTINGS.PIPELINES.BACK_TO_DEALS')"
                :title="$t('CRM.SETTINGS.PIPELINES.BACK_TO_DEALS')"
                @click="backToDeals"
              />
              <Button
                :label="$t('CRM.GENERAL.SAVE')"
                :is-loading="settingsSaving"
                :disabled="!canManage || settingsSaving"
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
                        :model-value="unsortedStage?.active !== false"
                        :disabled="
                          !canManage ||
                          !unsortedStage ||
                          referencesStore.ui.isSaving
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
                      :disabled="!canManage || stageOrderSaving"
                      @end="persistStageOrder"
                    >
                      <template #item="{ element: stage, index }">
                        <div class="flex shrink-0 items-stretch">
                          <button
                            v-if="canManage"
                            type="button"
                            class="group relative flex w-8 shrink-0 items-center justify-center"
                            :aria-label="$t('CRM.SETTINGS.STAGES.CREATE_TITLE')"
                            :title="$t('CRM.SETTINGS.STAGES.CREATE_TITLE')"
                            @click="openStageDrawer(null, index)"
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
                            :class="stage.active === false ? 'opacity-60' : ''"
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
                                class="w-full rounded-md border border-transparent bg-transparent px-1 py-1 text-sm font-semibold text-n-slate-12 outline-none transition hover:border-n-weak focus:border-n-brand focus:bg-n-surface-1"
                                :disabled="
                                  !canManage || referencesStore.ui.isSaving
                                "
                                @blur="saveInlineStageName(stage)"
                                @keydown.enter="$event.currentTarget.blur()"
                              />
                            </div>
                            <div class="grid gap-3 px-3 pb-3 pt-2">
                              <span
                                v-if="stage.default"
                                class="w-fit rounded-full bg-n-brand/10 px-2 py-0.5 text-[10px] font-semibold text-n-brand"
                              >
                                {{ $t('CRM.SETTINGS.STAGES.DEFAULT_BADGE') }}
                              </span>
                              <span
                                v-if="stage.active === false"
                                class="text-xs text-n-slate-9"
                              >
                                {{ $t('CRM.SETTINGS.STAGES.INACTIVE_BADGE') }}
                              </span>
                            </div>
                          </article>
                        </div>
                      </template>
                    </Draggable>

                    <button
                      v-if="canManage"
                      type="button"
                      class="group relative flex w-8 shrink-0 items-center justify-center"
                      :aria-label="$t('CRM.SETTINGS.STAGES.CREATE_TITLE')"
                      :title="$t('CRM.SETTINGS.STAGES.CREATE_TITLE')"
                      @click="openStageDrawer(null, movableStageRows.length)"
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
                          :disabled="!canManage || referencesStore.ui.isSaving"
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
                          :disabled="!canManage || referencesStore.ui.isSaving"
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
                            :disabled="
                              !canManage || referencesStore.ui.isSaving
                            "
                            @update:model-value="toggleInlineClosingReasons"
                          />
                        </div>
                        <template v-if="lossReasonsEnabled">
                          <TagInput
                            v-model="closingReasonDraft"
                            class="rounded-lg bg-n-surface-1 p-2 outline outline-1 outline-n-weak"
                            allow-create
                            :disabled="
                              !canManage || referencesStore.ui.isSaving
                            "
                            :auto-open-dropdown="false"
                            :placeholder="
                              $t(
                                'CRM.SETTINGS.STAGES.FORM.CLOSING_REASONS_PLACEHOLDER'
                              )
                            "
                          />
                          <Button
                            size="sm"
                            class="justify-self-end"
                            :is-loading="referencesStore.ui.isSaving"
                            :disabled="
                              !canManage ||
                              normalizedClosingReasonDraft.length === 0
                            "
                            :label="$t('CRM.GENERAL.SAVE')"
                            @click="saveInlineClosingReasons"
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
      v-model="stageDrawerOpen"
      width="sm"
      :title="
        stageForm.id
          ? $t('CRM.SETTINGS.STAGES.EDIT_TITLE')
          : $t('CRM.SETTINGS.STAGES.CREATE_TITLE')
      "
      :confirm-label="$t('CRM.GENERAL.SAVE')"
      :is-loading="referencesStore.ui.isSaving"
      :disable-confirm="stageFormDisableConfirm"
      @confirm="saveStage"
    >
      <div class="mx-auto grid w-full max-w-[26rem] gap-4">
        <Input
          v-if="!stageForm.id"
          :label="$t('CRM.SETTINGS.STAGES.FORM.NAME')"
          :model-value="stageForm.name"
          @update:model-value="stageForm.name = $event"
        />

        <template v-if="!stageFormIsTerminal">
          <div class="grid gap-3">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('CRM.SETTINGS.STAGES.FORM.COLOR') }}
            </span>
            <div class="flex flex-wrap gap-2">
              <button
                v-for="color in STAGE_STANDARD_COLORS"
                :key="color"
                type="button"
                class="size-8 rounded-full border-2 border-n-container transition-transform hover:scale-105 disabled:cursor-not-allowed disabled:opacity-30"
                :class="
                  stageForm.color?.toUpperCase() === color.toUpperCase()
                    ? 'ring-2 ring-n-slate-8 ring-offset-2 ring-offset-n-surface-1'
                    : ''
                "
                :style="{ backgroundColor: color }"
                :disabled="stageColorDisabled(color)"
                @click="stageForm.color = color"
              />
            </div>
            <SchedulingColorPicker v-model="stageForm.color" />
          </div>

          <div v-if="stageForm.id" class="flex items-center gap-3">
            <Switch
              :model-value="stageForm.active"
              @update:model-value="updateStageActive"
            />
            <div class="grid gap-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('CRM.SETTINGS.STAGES.FORM.ACTIVE') }}
              </span>
              <span class="text-xs text-n-slate-10">
                {{ $t('CRM.SETTINGS.STAGES.FORM.ACTIVE_HELP') }}
              </span>
            </div>
          </div>

          <div class="flex items-center gap-3">
            <Switch
              :model-value="stageForm.default"
              :disabled="!stageForm.active"
              @update:model-value="stageForm.default = $event"
            />
            <div class="grid gap-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('CRM.SETTINGS.STAGES.FORM.DEFAULT') }}
              </span>
              <span class="text-xs text-n-slate-10">
                {{ $t('CRM.SETTINGS.STAGES.FORM.DEFAULT_HELP') }}
              </span>
            </div>
          </div>

          <div class="grid gap-3 rounded-xl border border-n-weak p-4">
            <div class="grid gap-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('CRM.SETTINGS.STAGES.FORM.TRANSITION_REASONS') }}
              </span>
              <span class="text-xs leading-5 text-n-slate-10">
                {{ $t('CRM.SETTINGS.STAGES.FORM.TRANSITION_REASONS_HELP') }}
              </span>
            </div>
            <TagInput
              v-model="stageForm.transitionReasonOptions"
              class="rounded-lg bg-n-alpha-black2 p-2 outline outline-1 outline-n-weak"
              allow-create
              :auto-open-dropdown="false"
              :placeholder="
                $t('CRM.SETTINGS.STAGES.FORM.TRANSITION_REASONS_PLACEHOLDER')
              "
            />
            <div class="flex items-center gap-3">
              <Switch
                :model-value="stageForm.transitionReasonRequired"
                :disabled="normalizedStageFormTransitionReasons.length === 0"
                @update:model-value="
                  stageForm.transitionReasonRequired = $event
                "
              />
              <span class="text-sm text-n-slate-12">
                {{ $t('CRM.SETTINGS.STAGES.FORM.TRANSITION_REASONS_REQUIRED') }}
              </span>
            </div>
          </div>
        </template>
      </div>

      <template #footer>
        <div class="flex items-center justify-between gap-3">
          <Button
            v-if="stageForm.id && !stageFormIsTerminal"
            size="sm"
            color="ruby"
            variant="outline"
            :label="$t('CRM.SETTINGS.STAGES.DELETE')"
            @click="openDeleteStageDialog"
          />
          <div v-else />
          <div class="flex items-center gap-2">
            <Button
              size="sm"
              variant="faded"
              color="slate"
              :label="$t('SCHEDULING.GENERAL.CANCEL')"
              @click="stageDrawerOpen = false"
            />
            <Button
              size="sm"
              :is-loading="referencesStore.ui.isSaving"
              :disabled="stageFormDisableConfirm || referencesStore.ui.isSaving"
              :label="$t('CRM.GENERAL.SAVE')"
              @click="saveStage"
            />
          </div>
        </div>
      </template>
    </SchedulingDrawer>

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
      :is-loading="referencesStore.ui.isSaving"
      @close="stagePendingDelete = null"
      @confirm="deleteStage"
    />
  </SettingsLayout>
</template>
