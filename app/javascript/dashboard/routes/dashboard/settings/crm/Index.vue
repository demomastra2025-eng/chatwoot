<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import Draggable from 'vuedraggable';
import { getContrastingTextColor } from '@chatwoot/utils';

import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { useTouchPlans } from 'dashboard/composables/useTouchPlans';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TagInput from 'dashboard/components-next/taginput/TagInput.vue';
import TouchPlanSelectField from 'dashboard/components-next/Outbound/TouchPlanSelectField.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingColorPicker from 'dashboard/components-next/Scheduling/SchedulingColorPicker.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { formatCrmErrorMessage } from 'dashboard/stores/crm/shared';
import {
  DEFAULT_STAGE_COLOR,
  STAGE_STANDARD_COLORS,
  getUnavailableStageColors,
  pickStageColor,
} from 'dashboard/stores/crm/stageColors';

const referencesStore = useCrmReferencesStore();
const route = useRoute();
const router = useRouter();
const { checkPermissions } = usePolicy();
const { currentAccount, updateAccount } = useAccount();
const { isLoadingTouchPlans, loadTouchPlans, touchPlanOptionsForEntityKind } =
  useTouchPlans();
const { t } = useI18n();
const loadSettingsPipelines = () =>
  referencesStore.loadPipelines({ include_inactive_stages: true });
const normalizedDefaultStageColor = String(DEFAULT_STAGE_COLOR || '')
  .trim()
  .toUpperCase();

const stageDrawerOpen = ref(false);
const pipelineDeleteDialogRef = ref(null);
const pipelinePendingDelete = ref(null);
const stageDeleteDialogRef = ref(null);
const stagePendingDelete = ref(null);
const defaultDealTouchPlanId = ref(null);
const showArchivedPipelines = ref(false);
const pipelineNameDrafts = reactive({});
const pipelineLastSyncedNames = reactive({});
const pipelineSavingIds = reactive({});
const pipelineRows = ref([]);
const draggingPipelines = ref(false);
const pipelineOrderSaving = ref(false);
const stageRowsByPipeline = reactive({});
const draggingStagePipelineIds = reactive({});
const stageOrderSavingPipelineIds = reactive({});
const newPipelineDraft = ref(null);
const pipelineCreateSaving = ref(false);

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

const pipelineAutoCreateEnabled = pipeline =>
  Boolean(
    pipeline?.autoCreateDealOnChannelContact ??
      pipeline?.auto_create_deal_on_channel_contact
  );

const pipelineDefaultEnabled = pipeline => Boolean(pipeline?.default);

const pipelineDisplayRank = pipeline => {
  if (pipelineDefaultEnabled(pipeline)) return 0;
  return 1;
};

const sortPipelinesForSettings = pipelines =>
  [...pipelines].sort((left, right) => {
    const rankDiff = pipelineDisplayRank(left) - pipelineDisplayRank(right);
    if (rankDiff !== 0) return rankDiff;

    return Number(left.position ?? 0) - Number(right.position ?? 0);
  });

const stageForm = reactive({
  active: true,
  closingReasonOptions: [],
  closingReasonRequired: false,
  color: DEFAULT_STAGE_COLOR,
  default: false,
  id: null,
  name: '',
  outcome: 'open',
  pipelineId: '',
  position: '',
  transitionReasonOptions: [],
  transitionReasonRequired: false,
});

const pipelineColumns = computed(() => [
  {
    key: 'name',
    label: t('CRM.SETTINGS.PIPELINES.TABLE.NAME'),
    width: 'minmax(12rem, 1fr)',
  },
  {
    key: 'default',
    label: t('CRM.SETTINGS.PIPELINES.TABLE.DEFAULT'),
    title: t('CRM.SETTINGS.PIPELINES.FORM.DEFAULT'),
    width: '92px',
  },
  {
    key: 'autoCreate',
    label: t('CRM.SETTINGS.PIPELINES.TABLE.AUTO_CREATE'),
    title: t('CRM.SETTINGS.PIPELINES.FORM.AUTO_CREATE_DEAL_ON_CHANNEL_CONTACT'),
    width: '72px',
  },
  {
    key: 'stages',
    label: t('CRM.SETTINGS.PIPELINES.TABLE.STAGES'),
    width: 'minmax(20rem, 1.8fr)',
  },
  { key: 'actions', label: '', width: '156px', align: 'end' },
]);

const visiblePipelines = computed(() =>
  sortPipelinesForSettings(
    referencesStore.pipelines.filter(
      pipeline => showArchivedPipelines.value || pipeline.active
    )
  )
);

const pipelineGridTemplate = computed(() =>
  pipelineColumns.value
    .map(column => {
      const width = String(column.width || '1fr');
      return width.endsWith('fr') ? `minmax(0, ${width})` : width;
    })
    .join(' ')
);

const pipelineOptions = computed(() =>
  referencesStore.pipelines.map(pipeline => ({
    label: pipeline.name,
    value: pipeline.id,
  }))
);
const dealTouchPlanOptions = computed(() =>
  touchPlanOptionsForEntityKind('deal')
);
const TERMINAL_STAGE_OUTCOMES = new Set(['won', 'lost']);
const isTerminalStageOutcome = outcome =>
  TERMINAL_STAGE_OUTCOMES.has(String(outcome || '').toLowerCase());
const isTerminalStage = stage => isTerminalStageOutcome(stage?.outcome);
const stageFormIsTerminal = computed(() =>
  Boolean(stageForm.id && isTerminalStageOutcome(stageForm.outcome))
);

const stageFormCanBeDefault = computed(
  () =>
    !stageFormIsTerminal.value &&
    stageForm.active &&
    stageForm.outcome === 'open'
);

const normalizedTextValues = values => [
  ...new Set(
    (Array.isArray(values) ? values : [values])
      .map(value => String(value || '').trim())
      .filter(Boolean)
  ),
];

const stageFormClosingReasonOptions = computed(() =>
  normalizedTextValues(stageForm.closingReasonOptions)
);

const stageFormTransitionReasonOptions = computed(() =>
  normalizedTextValues(stageForm.transitionReasonOptions)
);

const stageFormHasInvalidClosingReasonRequirement = computed(
  () =>
    stageFormIsTerminal.value &&
    stageForm.closingReasonRequired &&
    stageFormClosingReasonOptions.value.length === 0
);

const stageFormHasInvalidTransitionReasonRequirement = computed(
  () =>
    !stageFormIsTerminal.value &&
    stageForm.transitionReasonRequired &&
    stageFormTransitionReasonOptions.value.length === 0
);

const stageFormDisableConfirm = computed(
  () =>
    !stageForm.name.trim() ||
    !stageForm.pipelineId ||
    stageFormHasInvalidClosingReasonRequirement.value ||
    stageFormHasInvalidTransitionReasonRequirement.value
);

const formatErrorMessage = error => formatCrmErrorMessage(error, t);

const syncFromAccount = () => {
  const accountSettings = currentAccount.value?.settings || {};
  defaultDealTouchPlanId.value =
    accountSettings.default_deal_touch_plan_id || null;
};

watch(currentAccount, syncFromAccount, { deep: true, immediate: true });

watch(
  () => [stageForm.active, stageForm.outcome],
  () => {
    if (!stageFormCanBeDefault.value) {
      stageForm.default = false;
    }
  }
);

function sortStages(stages) {
  return [...(stages || [])].sort(
    (left, right) =>
      Number(isTerminalStage(left)) - Number(isTerminalStage(right)) ||
      Number(left.position ?? 0) - Number(right.position ?? 0) ||
      Number(left.id ?? 0) - Number(right.id ?? 0)
  );
}

function cloneStages(stages) {
  return sortStages(stages).map(stage => ({ ...stage }));
}

watch(
  () =>
    referencesStore.pipelines.map(pipeline => ({
      id: String(pipeline.id),
      name: pipeline.name,
    })),
  pipelines => {
    const nextIds = new Set(pipelines.map(pipeline => pipeline.id));

    pipelines.forEach(pipeline => {
      const previousName = pipelineLastSyncedNames[pipeline.id];
      const currentDraft = pipelineNameDrafts[pipeline.id];

      if (
        currentDraft === undefined ||
        currentDraft === previousName ||
        previousName === undefined
      ) {
        pipelineNameDrafts[pipeline.id] = pipeline.name;
      }

      pipelineLastSyncedNames[pipeline.id] = pipeline.name;
    });

    Object.keys(pipelineNameDrafts).forEach(id => {
      if (!nextIds.has(id)) {
        delete pipelineNameDrafts[id];
      }
    });

    Object.keys(pipelineLastSyncedNames).forEach(id => {
      if (!nextIds.has(id)) {
        delete pipelineLastSyncedNames[id];
      }
    });
  },
  { immediate: true }
);

watch(
  visiblePipelines,
  pipelines => {
    if (draggingPipelines.value || pipelineOrderSaving.value) {
      return;
    }

    pipelineRows.value = [...pipelines];
  },
  { immediate: true }
);

watch(
  visiblePipelines,
  pipelines => {
    const nextIds = new Set(pipelines.map(pipeline => String(pipeline.id)));

    pipelines.forEach(pipeline => {
      const pipelineId = String(pipeline.id);

      if (
        draggingStagePipelineIds[pipelineId] ||
        stageOrderSavingPipelineIds[pipelineId]
      ) {
        return;
      }

      stageRowsByPipeline[pipelineId] = cloneStages(pipeline.stages);
    });

    Object.keys(stageRowsByPipeline).forEach(id => {
      if (!nextIds.has(id)) {
        delete stageRowsByPipeline[id];
      }
    });

    Object.keys(draggingStagePipelineIds).forEach(id => {
      if (!nextIds.has(id)) {
        delete draggingStagePipelineIds[id];
      }
    });

    Object.keys(stageOrderSavingPipelineIds).forEach(id => {
      if (!nextIds.has(id)) {
        delete stageOrderSavingPipelineIds[id];
      }
    });
  },
  { deep: true, immediate: true }
);

const pipelineRowClass = pipeline =>
  pipeline.active
    ? ''
    : 'bg-n-slate-2/70 text-n-slate-10 hover:!bg-n-slate-2/80';

const pipelineNameInputClass = pipeline =>
  pipeline.active
    ? 'font-medium shadow-none !bg-n-solid-1'
    : 'font-medium shadow-none !bg-n-slate-2 !text-n-slate-10';

const isPipelineSaving = pipelineId => Boolean(pipelineSavingIds[pipelineId]);

const setPipelineSaving = (pipelineId, isSaving) => {
  if (isSaving) {
    pipelineSavingIds[pipelineId] = true;
    return;
  }

  delete pipelineSavingIds[pipelineId];
};

const syncPipelineRows = () => {
  pipelineRows.value = [...visiblePipelines.value];
};

const buildPipelineSavePayload = (pipeline, overrides = {}) => {
  const autoCreateDealOnChannelContact =
    overrides.autoCreateDealOnChannelContact ??
    overrides.auto_create_deal_on_channel_contact ??
    pipelineAutoCreateEnabled(pipeline);

  return {
    active: overrides.active ?? pipeline.active,
    auto_create_deal_on_channel_contact: Boolean(
      autoCreateDealOnChannelContact
    ),
    default: Boolean(overrides.default ?? pipelineDefaultEnabled(pipeline)),
    id: pipeline.id,
    name:
      overrides.name ??
      String(
        pipelineNameDrafts[String(pipeline.id)] ?? pipeline.name ?? ''
      ).trim(),
    position:
      overrides.position ??
      (pipeline.position === '' || pipeline.position === undefined
        ? undefined
        : Number(pipeline.position)),
  };
};

const persistInlinePipeline = async (pipeline, overrides = {}) => {
  const pipelineId = String(pipeline.id);
  setPipelineSaving(pipelineId, true);

  try {
    const savedPipeline = await referencesStore.savePipeline(
      buildPipelineSavePayload(pipeline, overrides)
    );
    pipelineNameDrafts[pipelineId] = savedPipeline.name;
    pipelineLastSyncedNames[pipelineId] = savedPipeline.name;
    return savedPipeline;
  } catch (error) {
    pipelineNameDrafts[pipelineId] = pipeline.name;
    useAlert(formatErrorMessage(error));
    throw error;
  } finally {
    setPipelineSaving(pipelineId, false);
  }
};

const saveInlinePipelineName = async pipeline => {
  const pipelineId = String(pipeline.id);
  if (isPipelineSaving(pipelineId)) return;

  const nextName = String(
    pipelineNameDrafts[pipelineId] ?? pipeline.name ?? ''
  ).trim();
  const currentName = String(pipeline.name || '').trim();

  if (!nextName) {
    pipelineNameDrafts[pipelineId] = currentName;
    return;
  }

  if (nextName === currentName) {
    pipelineNameDrafts[pipelineId] = currentName;
    return;
  }

  await persistInlinePipeline(pipeline, { name: nextName });
};

const saveInlinePipelineDefault = async (pipeline, nextValue) => {
  if (isPipelineSaving(String(pipeline.id))) return;
  if (!pipeline.active) return;

  await persistInlinePipeline(pipeline, {
    default: Boolean(nextValue),
    name: pipeline.name,
  });
};

const saveInlinePipelineAutoCreate = async (pipeline, nextValue) => {
  if (isPipelineSaving(String(pipeline.id))) return;
  if (!pipeline.active) return;

  await persistInlinePipeline(pipeline, {
    auto_create_deal_on_channel_contact: Boolean(nextValue),
    name: pipeline.name,
  });
};

const toggleInlinePipelineArchived = async (pipeline, nextActive) => {
  if (isPipelineSaving(String(pipeline.id))) return;

  await persistInlinePipeline(pipeline, {
    active: nextActive,
    default: nextActive && pipelineDefaultEnabled(pipeline),
    name: pipeline.name,
  });

  useAlert(
    nextActive
      ? t('CRM.SETTINGS.PIPELINES.SUCCESS_RESTORED')
      : t('CRM.SETTINGS.PIPELINES.SUCCESS_ARCHIVED')
  );
};

const openDeletePipelineDialog = pipeline => {
  if (!pipeline || pipeline.active) return;

  pipelinePendingDelete.value = pipeline;
  pipelineDeleteDialogRef.value?.open();
};

const closeDeletePipelineDialog = () => {
  pipelinePendingDelete.value = null;
};

const canDeletePipeline = pipeline =>
  Boolean(pipeline) && Number(pipeline.dealCount || 0) === 0;

const deletePipelineTitle = pipeline => {
  if (!pipeline) {
    return t('CRM.SETTINGS.PIPELINES.DELETE');
  }

  return canDeletePipeline(pipeline)
    ? t('CRM.SETTINGS.PIPELINES.DELETE')
    : t('CRM.ERRORS.PIPELINE_HAS_DEALS');
};

const deletePipeline = async () => {
  if (!pipelinePendingDelete.value) return;

  try {
    await referencesStore.deletePipeline(pipelinePendingDelete.value);
    pipelineDeleteDialogRef.value?.close();
    useAlert(t('CRM.SETTINGS.PIPELINES.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const persistPipelineOrder = async () => {
  pipelineOrderSaving.value = true;

  try {
    const orderedVisiblePipelines = [...pipelineRows.value];
    const visibleIds = new Set(
      orderedVisiblePipelines.map(pipeline => Number(pipeline.id))
    );
    const hiddenPipelines = [...referencesStore.pipelines]
      .filter(pipeline => !visibleIds.has(Number(pipeline.id)))
      .sort((left, right) => left.position - right.position);
    const nextPipelineOrder = [...orderedVisiblePipelines, ...hiddenPipelines];

    const pipelineUpdates = nextPipelineOrder
      .map((pipeline, index) => ({
        ...pipeline,
        nextPosition: index,
      }))
      .filter(pipeline => Number(pipeline.position) !== pipeline.nextPosition);

    await Promise.all(
      pipelineUpdates.map(pipeline =>
        referencesStore.savePipeline(
          buildPipelineSavePayload(pipeline, {
            position: pipeline.nextPosition,
          })
        )
      )
    );

    await loadSettingsPipelines();
  } catch (error) {
    useAlert(formatErrorMessage(error));
    await loadSettingsPipelines();
  } finally {
    pipelineOrderSaving.value = false;
    draggingPipelines.value = false;
    syncPipelineRows();
  }
};

const handlePipelineDragStart = () => {
  draggingPipelines.value = true;
};

const handlePipelineDragEnd = async event => {
  if (event.oldIndex === event.newIndex) {
    draggingPipelines.value = false;
    syncPipelineRows();
    return;
  }

  await persistPipelineOrder();
};

const pipelineStagesById = pipelineId => {
  return (
    referencesStore.pipelines.find(
      pipeline => Number(pipeline.id) === Number(pipelineId)
    )?.stages || []
  );
};

const pipelineHasDefaultStage = pipelineId =>
  pipelineStagesById(pipelineId).some(stage => stage.default && stage.active);

const getStageRows = pipelineId => {
  return stageRowsByPipeline[String(pipelineId)] || [];
};

const setStageRows = (pipelineId, rows) => {
  stageRowsByPipeline[String(pipelineId)] = [...rows];
};

const isStageOrderSaving = pipelineId =>
  Boolean(stageOrderSavingPipelineIds[String(pipelineId)]);

const setStageOrderSaving = (pipelineId, isSaving) => {
  const key = String(pipelineId);

  if (isSaving) {
    stageOrderSavingPipelineIds[key] = true;
    return;
  }

  delete stageOrderSavingPipelineIds[key];
};

const setDraggingStagePipeline = (pipelineId, isDragging) => {
  const key = String(pipelineId);

  if (isDragging) {
    draggingStagePipelineIds[key] = true;
    return;
  }

  delete draggingStagePipelineIds[key];
};

const syncStageRowsForPipeline = pipelineId => {
  const pipeline =
    visiblePipelines.value.find(
      item => Number(item.id) === Number(pipelineId)
    ) ||
    referencesStore.pipelines.find(
      item => Number(item.id) === Number(pipelineId)
    );

  stageRowsByPipeline[String(pipelineId)] = cloneStages(pipeline?.stages);
};

const stageOrderBadgeStyle = color => {
  const resolvedColor = color || DEFAULT_STAGE_COLOR;

  return {
    backgroundColor: resolvedColor,
    color: getContrastingTextColor(resolvedColor),
  };
};

const defaultStageColor = ({
  currentStageId = stageForm.id,
  pipelineId = stageForm.pipelineId,
} = {}) => {
  return pickStageColor(
    pipelineStagesById(pipelineId),
    STAGE_STANDARD_COLORS,
    currentStageId
  );
};

const unavailableStageStandardColors = computed(
  () =>
    new Set(
      getUnavailableStageColors(
        pipelineStagesById(stageForm.pipelineId),
        STAGE_STANDARD_COLORS,
        stageForm.id
      )
    )
);

const isStageStandardColorDisabled = color => {
  const normalizedColor = String(color || '')
    .trim()
    .toUpperCase();

  if (normalizedColor === normalizedDefaultStageColor) {
    return false;
  }

  return (
    unavailableStageStandardColors.value.has(normalizedColor) &&
    stageForm.color?.toUpperCase() !== normalizedColor
  );
};

const stageStandardColorAriaLabel = color => {
  const suffix = isStageStandardColorDisabled(color)
    ? `, ${t('CRM.SETTINGS.STAGES.FORM.COLOR_UNAVAILABLE')}`
    : '';

  return `${t('CRM.SETTINGS.STAGES.FORM.COLOR')} ${color}${suffix}`;
};

const stageStandardColorTitle = color => {
  if (!isStageStandardColorDisabled(color)) {
    return color;
  }

  return `${color} · ${t('CRM.SETTINGS.STAGES.FORM.COLOR_UNAVAILABLE')}`;
};

const resetStageForm = () => {
  const firstPipelineId = pipelineOptions.value[0]?.value || '';

  Object.assign(stageForm, {
    active: true,
    closingReasonOptions: [],
    closingReasonRequired: false,
    color: defaultStageColor({
      currentStageId: null,
      pipelineId: firstPipelineId,
    }),
    default: false,
    id: null,
    name: '',
    outcome: 'open',
    pipelineId: firstPipelineId,
    position: '',
    transitionReasonOptions: [],
    transitionReasonRequired: false,
  });
};

const openNewPipelineRow = () => {
  if (newPipelineDraft.value) return;

  newPipelineDraft.value = {
    autoCreateDealOnChannelContact: false,
    default: false,
    name: '',
  };
};

const cancelNewPipelineRow = () => {
  newPipelineDraft.value = null;
};

const openStageDrawer = ({ pipeline, stage } = {}) => {
  if (stage) {
    Object.assign(stageForm, {
      active: stage.active,
      closingReasonOptions: normalizedTextValues(stage.closingReasonOptions),
      closingReasonRequired: Boolean(stage.closingReasonRequired),
      color:
        stage.color ||
        defaultStageColor({
          currentStageId: stage.id,
          pipelineId: stage.pipelineId,
        }),
      default: Boolean(stage.default),
      id: stage.id,
      name: stage.name,
      outcome: stage.outcome || 'open',
      pipelineId: stage.pipelineId,
      position: stage.position ?? '',
      transitionReasonOptions: normalizedTextValues(
        stage.transitionReasonOptions
      ),
      transitionReasonRequired: Boolean(stage.transitionReasonRequired),
    });
  } else {
    resetStageForm();
    stageForm.pipelineId =
      pipeline?.id || pipelineOptions.value[0]?.value || '';
    stageForm.color = defaultStageColor({
      currentStageId: null,
      pipelineId: stageForm.pipelineId,
    });
    stageForm.default = !pipelineHasDefaultStage(stageForm.pipelineId);
  }

  stageDrawerOpen.value = true;
};

const handleStagePipelineSelection = pipelineId => {
  stageForm.pipelineId = pipelineId;

  if (stageForm.id) return;

  stageForm.default = !pipelineHasDefaultStage(pipelineId);

  const normalizedColor = String(stageForm.color || '')
    .trim()
    .toUpperCase();
  const nextUnavailableColors = new Set(
    getUnavailableStageColors(
      pipelineStagesById(pipelineId),
      STAGE_STANDARD_COLORS
    )
  );

  if (
    !normalizedColor ||
    (nextUnavailableColors.has(normalizedColor) &&
      normalizedColor !== normalizedDefaultStageColor)
  ) {
    stageForm.color = defaultStageColor({
      currentStageId: null,
      pipelineId,
    });
  }
};

const saveNewPipeline = async () => {
  const nextName = String(newPipelineDraft.value?.name || '').trim();
  if (!nextName || pipelineCreateSaving.value) return;

  pipelineCreateSaving.value = true;

  try {
    await referencesStore.savePipeline({
      active: true,
      auto_create_deal_on_channel_contact: Boolean(
        newPipelineDraft.value?.autoCreateDealOnChannelContact
      ),
      default: Boolean(newPipelineDraft.value?.default),
      name: nextName,
    });
    useAlert(t('CRM.SETTINGS.PIPELINES.SUCCESS_SAVE'));
    newPipelineDraft.value = null;
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    pipelineCreateSaving.value = false;
  }
};

const buildStageSavePayload = () => {
  const basePayload = {
    id: stageForm.id,
    name: stageForm.name.trim(),
  };

  if (stageFormIsTerminal.value) {
    return {
      ...basePayload,
      closing_reason_options: stageFormClosingReasonOptions.value,
      closing_reason_required: Boolean(stageForm.closingReasonRequired),
    };
  }

  return {
    ...basePayload,
    active: stageForm.active,
    color: stageForm.color,
    default: Boolean(stageForm.default && stageFormCanBeDefault.value),
    outcome: 'open',
    pipelineId: Number(stageForm.pipelineId),
    transition_reason_options: stageFormTransitionReasonOptions.value,
    transition_reason_required: Boolean(stageForm.transitionReasonRequired),
  };
};

const saveStage = async () => {
  try {
    await referencesStore.saveStage(buildStageSavePayload());
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_SAVE'));
    stageDrawerOpen.value = false;
    resetStageForm();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const persistInlineStageOrder = async pipelineId => {
  if (!pipelineId || isStageOrderSaving(pipelineId)) return;

  setStageOrderSaving(pipelineId, true);

  try {
    const stageUpdates = getStageRows(pipelineId)
      .map((stage, index) => ({
        ...stage,
        nextPosition: index,
      }))
      .filter(
        stage =>
          !isTerminalStage(stage) &&
          Number(stage.position ?? 0) !== stage.nextPosition
      );

    await Promise.all(
      stageUpdates.map(stage =>
        referencesStore.saveStage({
          active: stage.active,
          color:
            stage.color ||
            defaultStageColor({
              currentStageId: stage.id,
              pipelineId: stage.pipelineId || pipelineId,
            }),
          id: stage.id,
          name: stage.name,
          outcome: stage.outcome || 'open',
          pipelineId: Number(stage.pipelineId || pipelineId),
          position: stage.nextPosition,
        })
      )
    );

    await loadSettingsPipelines();
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_REORDER'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
    await loadSettingsPipelines();
  } finally {
    setStageOrderSaving(pipelineId, false);
    setDraggingStagePipeline(pipelineId, false);
    syncStageRowsForPipeline(pipelineId);
  }
};

const handleStageDragStart = pipelineId => {
  setDraggingStagePipeline(pipelineId, true);
};

const handleStageDragEnd = async (pipelineId, event) => {
  if (event.oldIndex === event.newIndex) {
    setDraggingStagePipeline(pipelineId, false);
    syncStageRowsForPipeline(pipelineId);
    return;
  }

  await persistInlineStageOrder(pipelineId);
};

const openDeleteStageDialog = stage => {
  const targetStage =
    stage ||
    (stageForm.id
      ? {
          id: stageForm.id,
          name: stageForm.name,
          pipelineId: stageForm.pipelineId,
        }
      : null);

  if (!targetStage) return;

  stagePendingDelete.value = targetStage;
  stageDeleteDialogRef.value?.open();
};

const closeDeleteStageDialog = () => {
  stagePendingDelete.value = null;
};

const deleteStage = async () => {
  if (!stagePendingDelete.value) return;

  try {
    await referencesStore.deleteStage(stagePendingDelete.value);
    stageDeleteDialogRef.value?.close();
    stageDrawerOpen.value = false;
    resetStageForm();
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const routeQueryValue = key => {
  const value = route.query[key];
  return Array.isArray(value) ? value[0] : value;
};

const clearRouteActionQuery = async keys => {
  const nextQuery = { ...route.query };
  delete nextQuery.action;
  keys.forEach(key => {
    delete nextQuery[key];
  });

  await router.replace({ query: nextQuery });
};

const consumeRouteAction = async () => {
  if (!canManage.value) {
    return;
  }

  const action = routeQueryValue('action');

  if (action === 'create-stage') {
    const requestedPipelineId = Number(routeQueryValue('pipelineId'));
    const pipeline =
      referencesStore.pipelines.find(
        item => Number(item.id) === requestedPipelineId
      ) || referencesStore.pipelines[0];

    if (pipeline) {
      openStageDrawer({ pipeline });
    }

    await clearRouteActionQuery(['pipelineId']);
  }
};

const saveDefaultDealTouchPlan = async () => {
  try {
    await updateAccount({
      default_deal_touch_plan_id: defaultDealTouchPlanId.value,
    });
    useAlert(t('GENERAL_SETTINGS.UPDATE.SUCCESS'));
  } catch (error) {
    syncFromAccount();
    useAlert(formatErrorMessage(error) || t('GENERAL_SETTINGS.UPDATE.ERROR'));
  }
};

onMounted(async () => {
  await loadTouchPlans();
  if (dealsEnabled.value) {
    await loadSettingsPipelines();
  }

  resetStageForm();
  await consumeRouteAction();
});
</script>

<template>
  <SettingsLayout
    :is-loading="referencesStore.ui.isLoadingPipelines"
    :loading-message="$t('CRM.SETTINGS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader :title="$t('CRM.SETTINGS.TITLE')" />
    </template>

    <template #loading>
      <div class="flex justify-center py-16">
        <Spinner class="!h-8 !w-8" />
      </div>
    </template>

    <template #body>
      <div class="grid gap-10">
        <SchedulingErrorState
          v-if="referencesStore.ui.error"
          :title="$t('CRM.ERRORS.LOAD_TITLE')"
          :description="formatErrorMessage(referencesStore.ui.error)"
          @retry="$router.go(0)"
        />

        <SchedulingFormFieldGroup
          v-if="dealsEnabled"
          :framed="false"
          :title="$t('CRM.SETTINGS.DEFAULT_TOUCH_PLAN.DEAL_TITLE')"
          :description="$t('CRM.SETTINGS.DEFAULT_TOUCH_PLAN.DEAL_DESCRIPTION')"
        >
          <div
            class="mt-3 grid gap-4 rounded-2xl bg-n-solid-2 p-5 outline outline-1 outline-n-container shadow-sm"
          >
            <TouchPlanSelectField
              v-model="defaultDealTouchPlanId"
              :label="$t('CRM.SETTINGS.DEFAULT_TOUCH_PLAN.LABEL')"
              :description="$t('CRM.SETTINGS.DEFAULT_TOUCH_PLAN.NOTE')"
              :options="dealTouchPlanOptions"
              :placeholder="$t('CRM.SETTINGS.DEFAULT_TOUCH_PLAN.PLACEHOLDER')"
              :disabled="!canManage || isLoadingTouchPlans"
            />

            <div>
              <Button
                :label="$t('CRM.SETTINGS.DEFAULT_TOUCH_PLAN.SAVE')"
                size="sm"
                :disabled="!canManage || isLoadingTouchPlans"
                @click="saveDefaultDealTouchPlan"
              />
            </div>
          </div>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          v-if="dealsEnabled"
          :framed="false"
          :title="$t('CRM.SETTINGS.PIPELINES.TITLE')"
          :description="$t('CRM.SETTINGS.PIPELINES.DESCRIPTION')"
        >
          <div
            class="mt-3 overflow-x-auto rounded-2xl bg-n-solid-2 outline outline-1 outline-n-container shadow-sm"
          >
            <div
              class="grid min-w-[980px] border-b border-n-weak bg-n-surface-2/80 px-5 py-3 text-[11px] font-semibold uppercase tracking-[0.08em] text-n-slate-10 backdrop-blur"
              :style="{ gridTemplateColumns: pipelineGridTemplate }"
            >
              <div
                v-for="column in pipelineColumns"
                :key="column.key"
                class="min-w-0 truncate"
                :class="[
                  column.align === 'end' ? 'text-end' : 'text-start',
                  column.key === 'stages' ? 'pl-4' : '',
                ]"
                :title="column.title || column.label"
              >
                {{ column.label }}
              </div>
            </div>

            <div
              v-if="pipelineRows.length === 0 && !newPipelineDraft"
              class="px-5 py-10 text-sm text-center text-n-slate-11"
            >
              {{ $t('SCHEDULING.GENERAL.NO_DATA') }}
            </div>

            <Draggable
              v-if="pipelineRows.length"
              v-model="pipelineRows"
              item-key="id"
              handle=".drag-handle"
              animation="200"
              ghost-class="pipeline-ghost"
              class="divide-y divide-n-weak"
              @start="handlePipelineDragStart"
              @end="handlePipelineDragEnd"
            >
              <template #item="{ element: row }">
                <div
                  class="grid min-w-[980px] items-center gap-3 px-5 py-3 text-sm text-n-slate-12 transition-colors hover:bg-n-alpha-1"
                  :class="pipelineRowClass(row)"
                  :style="{ gridTemplateColumns: pipelineGridTemplate }"
                >
                  <div class="min-w-0">
                    <div class="flex items-center gap-3">
                      <button
                        type="button"
                        class="drag-handle inline-flex size-10 shrink-0 items-center justify-center rounded-lg transition-colors"
                        :class="
                          row.active && !pipelineOrderSaving
                            ? 'cursor-grab text-n-slate-10 hover:bg-n-alpha-black2 hover:text-n-slate-12 active:cursor-grabbing'
                            : 'cursor-default text-n-slate-8'
                        "
                        :disabled="!row.active || pipelineOrderSaving"
                        :title="$t('CRM.SETTINGS.PIPELINES.DRAG')"
                      >
                        <span
                          class="i-lucide-grip-vertical size-5"
                          aria-hidden="true"
                        />
                      </button>

                      <div class="min-w-0 flex-1 grid gap-1">
                        <div class="flex flex-wrap items-center gap-2">
                          <Input
                            class="w-full min-w-0 max-w-[10.5rem]"
                            :model-value="
                              pipelineNameDrafts[String(row.id)] ?? row.name
                            "
                            size="sm"
                            :disabled="
                              !row.active ||
                              isPipelineSaving(String(row.id)) ||
                              pipelineOrderSaving
                            "
                            :custom-input-class="pipelineNameInputClass(row)"
                            @update:model-value="
                              pipelineNameDrafts[String(row.id)] = $event
                            "
                            @blur="saveInlinePipelineName(row)"
                            @enter="saveInlinePipelineName(row)"
                          />
                          <span
                            v-if="!row.active"
                            class="inline-flex rounded-full bg-n-slate-3 px-2 py-1 text-[11px] font-medium text-n-slate-10"
                          >
                            {{ $t('CRM.SETTINGS.PIPELINES.ARCHIVED_STATUS') }}
                          </span>
                        </div>
                      </div>
                    </div>
                  </div>

                  <div class="min-w-0 pl-3">
                    <div class="flex justify-start">
                      <Switch
                        :model-value="pipelineDefaultEnabled(row)"
                        :disabled="
                          !row.active ||
                          isPipelineSaving(String(row.id)) ||
                          pipelineOrderSaving
                        "
                        :title="$t('CRM.SETTINGS.PIPELINES.FORM.DEFAULT')"
                        @update:model-value="
                          saveInlinePipelineDefault(row, $event)
                        "
                      />
                    </div>
                  </div>

                  <div class="min-w-0 pl-3">
                    <div class="flex justify-start">
                      <Switch
                        :model-value="pipelineAutoCreateEnabled(row)"
                        :disabled="
                          !row.active ||
                          isPipelineSaving(String(row.id)) ||
                          pipelineOrderSaving
                        "
                        :title="
                          $t(
                            'CRM.SETTINGS.PIPELINES.FORM.AUTO_CREATE_DEAL_ON_CHANNEL_CONTACT'
                          )
                        "
                        @update:model-value="
                          saveInlinePipelineAutoCreate(row, $event)
                        "
                      />
                    </div>
                  </div>

                  <div class="min-w-0 pl-4">
                    <div class="flex min-w-0 flex-wrap items-center gap-2">
                      <Draggable
                        v-if="getStageRows(row.id).length"
                        :model-value="getStageRows(row.id)"
                        item-key="id"
                        handle=".pipeline-stage-drag-handle"
                        animation="200"
                        ghost-class="pipeline-ghost"
                        class="inline-flex min-w-0 flex-wrap items-center gap-2"
                        :disabled="
                          !canManage ||
                          !row.active ||
                          isStageOrderSaving(row.id)
                        "
                        @update:model-value="setStageRows(row.id, $event)"
                        @start="handleStageDragStart(row.id)"
                        @end="handleStageDragEnd(row.id, $event)"
                      >
                        <template #item="{ element: stage, index }">
                          <div
                            class="inline-flex min-w-0 max-w-full items-center gap-1 rounded-full px-0.5 py-0.5 text-xs outline outline-1"
                            :class="
                              row.active
                                ? 'bg-n-alpha-black2 text-n-slate-12 outline-n-weak'
                                : 'bg-n-slate-2 text-n-slate-10 outline-n-container'
                            "
                          >
                            <button
                              type="button"
                              class="inline-flex min-w-0 max-w-full items-center gap-2 rounded-full border-0 bg-transparent px-2 py-1 text-left"
                              :disabled="
                                !row.active || isStageOrderSaving(row.id)
                              "
                              @click="openStageDrawer({ stage })"
                            >
                              <span
                                class="inline-flex h-4 min-w-4 shrink-0 items-center justify-center rounded-full px-1 text-[9px] font-semibold tabular-nums border border-black/10 dark:border-white/10"
                                :style="stageOrderBadgeStyle(stage.color)"
                              >
                                {{ index + 1 }}
                              </span>
                              <span class="truncate">{{ stage.name }}</span>
                              <span
                                v-if="stage.default"
                                class="inline-flex shrink-0 rounded-full bg-n-brand/10 px-2 py-0.5 text-[10px] font-semibold text-n-brand"
                              >
                                {{ $t('CRM.SETTINGS.STAGES.DEFAULT_BADGE') }}
                              </span>
                            </button>
                            <button
                              v-if="
                                canManage &&
                                row.active &&
                                !isTerminalStage(stage)
                              "
                              type="button"
                              class="pipeline-stage-drag-handle inline-flex size-7 shrink-0 items-center justify-center rounded-full text-n-slate-10 transition-colors hover:bg-n-alpha-black2 hover:text-n-slate-12"
                              :disabled="isStageOrderSaving(row.id)"
                              :title="$t('CRM.SETTINGS.STAGES.REORDER')"
                            >
                              <span
                                class="i-lucide-grip-vertical size-4"
                                aria-hidden="true"
                              />
                            </button>
                          </div>
                        </template>
                      </Draggable>

                      <button
                        v-if="canManage && row.active"
                        type="button"
                        class="inline-flex min-w-0 items-center gap-2 rounded-full border border-dashed border-n-container bg-transparent px-3 py-1.5 text-xs font-medium text-n-slate-10 transition-colors hover:border-n-slate-8 hover:bg-n-alpha-black2 hover:text-n-slate-12"
                        :disabled="isStageOrderSaving(row.id)"
                        @click="openStageDrawer({ pipeline: row })"
                      >
                        <span
                          class="inline-flex size-4 shrink-0 items-center justify-center rounded-full bg-n-alpha-black2"
                          aria-hidden="true"
                        >
                          <span class="i-lucide-plus size-3" />
                        </span>
                        <span class="truncate">
                          {{ $t('CRM.SETTINGS.STAGES.CREATE_TITLE') }}
                        </span>
                      </button>
                    </div>
                  </div>

                  <div class="min-w-0 text-end">
                    <div class="flex justify-end gap-1">
                      <Button
                        v-if="canManage"
                        size="sm"
                        :color="row.active ? 'ruby' : 'slate'"
                        variant="ghost"
                        :icon="
                          row.active
                            ? 'i-lucide-archive'
                            : 'i-lucide-rotate-ccw'
                        "
                        @click="toggleInlinePipelineArchived(row, !row.active)"
                      />
                      <Button
                        v-if="canManage && !row.active"
                        size="sm"
                        color="ruby"
                        variant="ghost"
                        icon="i-lucide-trash"
                        :disabled="!canDeletePipeline(row)"
                        :title="deletePipelineTitle(row)"
                        @click="openDeletePipelineDialog(row)"
                      />
                    </div>
                  </div>
                </div>
              </template>
            </Draggable>

            <div v-if="newPipelineDraft" class="border-t border-n-weak">
              <div
                class="grid min-w-[980px] items-center gap-3 px-5 py-3 text-sm text-n-slate-12 bg-n-solid-1"
                :style="{ gridTemplateColumns: pipelineGridTemplate }"
              >
                <div class="min-w-0">
                  <div class="flex items-center gap-3">
                    <span
                      class="inline-flex size-10 shrink-0 items-center justify-center rounded-lg text-n-slate-8"
                      aria-hidden="true"
                    >
                      <span class="i-lucide-plus size-5" />
                    </span>
                    <div class="min-w-0 flex-1 grid gap-1">
                      <Input
                        class="w-full min-w-0 max-w-[10.5rem]"
                        :model-value="newPipelineDraft.name"
                        size="sm"
                        :disabled="pipelineCreateSaving"
                        custom-input-class="font-medium shadow-none !bg-n-solid-1"
                        @update:model-value="newPipelineDraft.name = $event"
                        @enter="saveNewPipeline"
                      />
                    </div>
                  </div>
                </div>

                <div class="min-w-0 pl-3">
                  <div class="flex justify-start">
                    <Switch
                      :model-value="newPipelineDraft.default"
                      :title="$t('CRM.SETTINGS.PIPELINES.FORM.DEFAULT')"
                      :disabled="pipelineCreateSaving"
                      @update:model-value="newPipelineDraft.default = $event"
                    />
                  </div>
                </div>

                <div class="min-w-0 pl-3">
                  <div class="flex justify-start">
                    <Switch
                      :model-value="
                        newPipelineDraft.autoCreateDealOnChannelContact
                      "
                      :title="
                        $t(
                          'CRM.SETTINGS.PIPELINES.FORM.AUTO_CREATE_DEAL_ON_CHANNEL_CONTACT'
                        )
                      "
                      :disabled="pipelineCreateSaving"
                      @update:model-value="
                        newPipelineDraft.autoCreateDealOnChannelContact = $event
                      "
                    />
                  </div>
                </div>

                <div class="min-w-0 flex items-center pl-4">
                  <span class="text-xs leading-5 text-n-slate-10">
                    {{ $t('CRM.SETTINGS.PIPELINES.NEW_PIPELINE_HELP') }}
                  </span>
                </div>

                <div class="min-w-0 flex items-center justify-end">
                  <div class="flex shrink-0 justify-end gap-2">
                    <Button
                      size="sm"
                      color="slate"
                      variant="faded"
                      :disabled="pipelineCreateSaving"
                      :label="$t('SCHEDULING.GENERAL.CANCEL')"
                      @click="cancelNewPipelineRow"
                    />
                    <Button
                      size="sm"
                      :is-loading="pipelineCreateSaving"
                      :disabled="
                        !newPipelineDraft.name.trim() || pipelineCreateSaving
                      "
                      :label="$t('CRM.GENERAL.SAVE')"
                      @click="saveNewPipeline"
                    />
                  </div>
                </div>
              </div>
            </div>
          </div>

          <template #headerActions>
            <div class="flex items-center gap-3">
              <label
                class="flex cursor-pointer items-center gap-2 text-sm text-n-slate-12"
              >
                <Checkbox
                  :model-value="showArchivedPipelines"
                  @update:model-value="showArchivedPipelines = $event"
                />
                <span>{{ $t('CRM.SETTINGS.PIPELINES.SHOW_ARCHIVED') }}</span>
              </label>
              <Button
                v-if="canManage"
                size="sm"
                :disabled="Boolean(newPipelineDraft)"
                icon="i-lucide-plus"
                :label="$t('CRM.SETTINGS.PIPELINES.ADD')"
                @click="openNewPipelineRow()"
              />
            </div>
          </template>
        </SchedulingFormFieldGroup>
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
        <SchedulingSelectField
          :label="$t('CRM.SETTINGS.STAGES.FORM.PIPELINE')"
          :model-value="stageForm.pipelineId"
          :options="pipelineOptions"
          :disabled="Boolean(stageForm.id)"
          @update:model-value="handleStagePipelineSelection($event)"
        />
        <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_auto] md:items-end">
          <Input
            class="min-w-0"
            :label="$t('CRM.SETTINGS.STAGES.FORM.NAME')"
            :model-value="stageForm.name"
            @update:model-value="stageForm.name = $event"
          />
          <label
            v-if="stageForm.id && !stageFormIsTerminal"
            class="mb-0 flex h-10 cursor-pointer items-center gap-2 rounded-lg px-3 text-sm text-n-slate-12 outline outline-1 outline-n-weak"
          >
            <Checkbox
              :model-value="!stageForm.active"
              @update:model-value="stageForm.active = !$event"
            />
            <span class="whitespace-nowrap">
              {{ $t('CRM.SETTINGS.STAGES.FORM.DEACTIVATE') }}
            </span>
          </label>
        </div>
        <div
          v-if="stageFormIsTerminal"
          class="grid gap-3 rounded-xl border border-n-weak p-3"
        >
          <div class="grid gap-1">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('CRM.SETTINGS.STAGES.FORM.CLOSING_REASONS') }}
            </span>
            <span class="text-xs leading-5 text-n-slate-11">
              {{ $t('CRM.SETTINGS.STAGES.FORM.CLOSING_REASONS_HELP') }}
            </span>
          </div>
          <TagInput
            v-model="stageForm.closingReasonOptions"
            class="rounded-lg bg-n-alpha-black2 p-2 outline outline-1 outline-n-weak"
            allow-create
            :auto-open-dropdown="false"
            :placeholder="
              $t('CRM.SETTINGS.STAGES.FORM.CLOSING_REASONS_PLACEHOLDER')
            "
          />
          <div class="flex items-center gap-3">
            <Switch
              :model-value="stageForm.closingReasonRequired"
              @update:model-value="stageForm.closingReasonRequired = $event"
            />
            <div class="grid gap-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('CRM.SETTINGS.STAGES.FORM.CLOSING_REASONS_REQUIRED') }}
              </span>
              <span class="text-xs leading-5 text-n-slate-11">
                {{
                  $t('CRM.SETTINGS.STAGES.FORM.CLOSING_REASONS_REQUIRED_HELP')
                }}
              </span>
            </div>
          </div>
          <p
            v-if="stageFormHasInvalidClosingReasonRequirement"
            class="mb-0 text-xs leading-5 text-n-ruby-10"
          >
            {{ $t('CRM.SETTINGS.STAGES.FORM.CLOSING_REASONS_REQUIRED_ERROR') }}
          </p>
        </div>
        <div v-if="!stageFormIsTerminal" class="grid gap-3">
          <span class="text-sm font-medium text-n-slate-12">
            {{ $t('CRM.SETTINGS.STAGES.FORM.COLOR') }}
          </span>
          <div class="flex flex-wrap gap-2">
            <button
              v-for="color in STAGE_STANDARD_COLORS"
              :key="color"
              type="button"
              class="relative size-8 rounded-full border-2 transition-transform hover:scale-105 disabled:cursor-not-allowed disabled:opacity-100 disabled:hover:scale-100"
              :class="[
                stageForm.color?.toUpperCase() === color.toUpperCase()
                  ? 'ring-2 ring-offset-2 ring-offset-n-surface-1 ring-n-slate-8 border-n-slate-9'
                  : 'border-n-container',
                isStageStandardColorDisabled(color)
                  ? 'border-n-slate-8 shadow-[inset_0_0_0_1px_rgba(15,23,42,0.08)]'
                  : '',
              ]"
              :style="{ backgroundColor: color }"
              :disabled="isStageStandardColorDisabled(color)"
              :aria-label="stageStandardColorAriaLabel(color)"
              :title="stageStandardColorTitle(color)"
              @click="stageForm.color = color"
            >
              <span
                v-if="isStageStandardColorDisabled(color)"
                class="pointer-events-none absolute -bottom-0.5 -right-0.5 flex size-4 items-center justify-center rounded-full bg-n-surface-1 text-n-slate-12 outline outline-1 outline-n-container shadow-sm"
                aria-hidden="true"
              >
                <span class="size-2.5 i-lucide-slash" />
              </span>
            </button>
          </div>
          <div class="grid gap-2 md:max-w-xs">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('CRM.SETTINGS.STAGES.FORM.CUSTOM_COLOR') }}
            </span>
            <SchedulingColorPicker v-model="stageForm.color" />
          </div>
        </div>
        <div v-if="!stageFormIsTerminal" class="flex items-center gap-3">
          <Switch
            :model-value="stageForm.default"
            :disabled="!stageFormCanBeDefault"
            @update:model-value="stageForm.default = $event"
          />
          <div class="grid gap-1">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('CRM.SETTINGS.STAGES.FORM.DEFAULT') }}
            </span>
            <span class="text-xs text-n-slate-11">
              {{ $t('CRM.SETTINGS.STAGES.FORM.DEFAULT_HELP') }}
            </span>
          </div>
        </div>
        <div
          v-if="!stageFormIsTerminal"
          class="grid gap-3 rounded-xl border border-n-weak p-3"
        >
          <div class="grid gap-1">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('CRM.SETTINGS.STAGES.FORM.TRANSITION_REASONS') }}
            </span>
            <span class="text-xs leading-5 text-n-slate-11">
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
              @update:model-value="stageForm.transitionReasonRequired = $event"
            />
            <div class="grid gap-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('CRM.SETTINGS.STAGES.FORM.TRANSITION_REASONS_REQUIRED') }}
              </span>
              <span class="text-xs leading-5 text-n-slate-11">
                {{
                  $t(
                    'CRM.SETTINGS.STAGES.FORM.TRANSITION_REASONS_REQUIRED_HELP'
                  )
                }}
              </span>
            </div>
          </div>
          <p
            v-if="stageFormHasInvalidTransitionReasonRequirement"
            class="mb-0 text-xs leading-5 text-n-ruby-10"
          >
            {{
              $t('CRM.SETTINGS.STAGES.FORM.TRANSITION_REASONS_REQUIRED_ERROR')
            }}
          </p>
        </div>
      </div>

      <template #footer>
        <div class="flex items-center justify-between gap-3">
          <Button
            v-if="stageForm.id && !stageFormIsTerminal"
            size="sm"
            color="ruby"
            variant="outline"
            :label="$t('CRM.SETTINGS.STAGES.DELETE')"
            @click="openDeleteStageDialog()"
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
      :is-loading="referencesStore.ui.isSaving"
      @close="closeDeletePipelineDialog"
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
      :is-loading="referencesStore.ui.isSaving"
      @close="closeDeleteStageDialog"
      @confirm="deleteStage"
    />
  </SettingsLayout>
</template>

<style scoped lang="scss">
.pipeline-ghost {
  @apply opacity-50 bg-n-slate-3 dark:bg-n-slate-9;
}
</style>
