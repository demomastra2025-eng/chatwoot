<script setup>
import { computed, nextTick, onMounted, reactive, ref, watch } from 'vue';
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
const pipelineSearchQuery = ref('');
const pipelineRows = ref([]);
const draggingPipelines = ref(false);
const pipelineOrderSaving = ref(false);
const selectedStagePipelineId = ref('');
const selectedStageOrderRows = ref([]);
const selectedTerminalStageRows = ref([]);
const selectedStageDeletedIds = ref([]);
const selectedStageOrderBaseline = ref('');
const selectedStageOrderSaving = ref(false);
const stageDeletionInfo = ref(null);
const stageDeletionChecking = ref(false);
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
  draftKey: '',
  id: null,
  isNew: false,
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

const normalizeSearchText = value =>
  String(value || '')
    .trim()
    .toLowerCase();

const pipelineMatchesSearch = (pipeline, query) => {
  if (!query) return true;

  const searchableValues = [
    pipeline.name,
    pipeline.code,
    pipeline.active ? t('CRM.GENERAL.ACTIVE') : t('CRM.GENERAL.ARCHIVED'),
    ...(pipeline.stages || []).flatMap(stage => [
      stage.name,
      stage.code,
      stage.outcome,
      stage.default ? t('CRM.SETTINGS.STAGES.DEFAULT_BADGE') : '',
      ...(stage.closingReasonOptions || []),
      ...(stage.transitionReasonOptions || []),
    ]),
  ];

  return searchableValues.some(value =>
    normalizeSearchText(value).includes(query)
  );
};

const visiblePipelines = computed(() => {
  const query = normalizeSearchText(pipelineSearchQuery.value);

  return sortPipelinesForSettings(
    referencesStore.pipelines.filter(
      pipeline =>
        (showArchivedPipelines.value || pipeline.active) &&
        pipelineMatchesSearch(pipeline, query)
    )
  );
});

const pipelineEmptyStateMessage = computed(() =>
  pipelineSearchQuery.value
    ? t('CRM.SETTINGS.PIPELINES.EMPTY_FILTERED')
    : t('SCHEDULING.GENERAL.NO_DATA')
);
const pipelineSearchActive = computed(() =>
  Boolean(normalizeSearchText(pipelineSearchQuery.value))
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
const activePipelineOptions = computed(() =>
  sortPipelinesForSettings(
    referencesStore.pipelines.filter(pipeline => pipeline.active)
  ).map(pipeline => ({
    label: pipeline.name,
    value: String(pipeline.id),
  }))
);
const selectedStagePipeline = computed(
  () =>
    referencesStore.pipelines.find(
      pipeline => Number(pipeline.id) === Number(selectedStagePipelineId.value)
    ) || null
);
const normalizedTextValues = values => [
  ...new Set(
    (Array.isArray(values) ? values : [values])
      .map(value => String(value || '').trim())
      .filter(Boolean)
  ),
];
const stageDraftSnapshot = () =>
  JSON.stringify({
    deletedIds: [...selectedStageDeletedIds.value].sort(
      (left, right) => left - right
    ),
    open: selectedStageOrderRows.value.map(stage => ({
      active: Boolean(stage.active),
      color: stage.color,
      default: Boolean(stage.default),
      id: stage.id,
      isNew: Boolean(stage.isNew),
      name: stage.name,
      transitionReasonOptions: normalizedTextValues(
        stage.transitionReasonOptions
      ),
      transitionReasonRequired: Boolean(stage.transitionReasonRequired),
    })),
    terminal: selectedTerminalStageRows.value.map(stage => ({
      closingReasonOptions: normalizedTextValues(stage.closingReasonOptions),
      closingReasonRequired: Boolean(stage.closingReasonRequired),
      id: stage.id,
      name: stage.name,
    })),
  });

const selectedStageOrderIsDirty = computed(
  () => stageDraftSnapshot() !== selectedStageOrderBaseline.value
);
const selectedStageDraftCanSave = computed(() => {
  const activeStages = selectedStageOrderRows.value.filter(
    stage => stage.active
  );
  const openStagesAreValid = selectedStageOrderRows.value.every(
    stage =>
      stage.name.trim() &&
      (!stage.transitionReasonRequired ||
        normalizedTextValues(stage.transitionReasonOptions).length > 0)
  );
  const terminalStagesAreValid = selectedTerminalStageRows.value.every(
    stage =>
      stage.name.trim() &&
      (!stage.closingReasonRequired ||
        normalizedTextValues(stage.closingReasonOptions).length > 0)
  );

  return (
    activeStages.length > 0 && openStagesAreValid && terminalStagesAreValid
  );
});
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
  return sortStages(stages).map(stage => ({
    ...stage,
    closingReasonOptions: [...(stage.closingReasonOptions || [])],
    draftKey: String(stage.id),
    isNew: false,
    transitionReasonOptions: [...(stage.transitionReasonOptions || [])],
  }));
}

const syncSelectedStageOrderDraft = () => {
  const stages = cloneStages(selectedStagePipeline.value?.stages);
  selectedStageOrderRows.value = stages.filter(
    stage => !isTerminalStage(stage)
  );
  selectedTerminalStageRows.value = stages.filter(isTerminalStage);
  selectedStageDeletedIds.value = [];
  selectedStageOrderBaseline.value = stageDraftSnapshot();
};

watch(
  activePipelineOptions,
  options => {
    if (!options.length) {
      selectedStagePipelineId.value = '';
      return;
    }

    if (
      !options.some(
        option => String(option.value) === String(selectedStagePipelineId.value)
      )
    ) {
      const defaultPipeline = referencesStore.pipelines.find(
        pipeline => pipeline.active && pipeline.default
      );
      selectedStagePipelineId.value = String(
        defaultPipeline?.id || options[0].value
      );
    }
  },
  { deep: true, immediate: true }
);

watch(selectedStagePipelineId, syncSelectedStageOrderDraft, {
  immediate: true,
});

watch(
  selectedStagePipeline,
  () => {
    if (!selectedStageOrderIsDirty.value) syncSelectedStageOrderDraft();
  },
  { deep: true }
);

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
  if (pipelineSearchActive.value) {
    draggingPipelines.value = false;
    syncPipelineRows();
    return;
  }

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
  if (pipelineSearchActive.value) return;
  draggingPipelines.value = true;
};

const handlePipelineDragEnd = async event => {
  if (pipelineSearchActive.value) {
    draggingPipelines.value = false;
    syncPipelineRows();
    return;
  }

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
  String(pipelineId) === String(selectedStagePipelineId.value)
    ? selectedStageOrderRows.value.some(stage => stage.default && stage.active)
    : pipelineStagesById(pipelineId).some(
        stage => stage.default && stage.active
      );

const getStageRows = pipelineId => sortStages(pipelineStagesById(pipelineId));

const selectStagePipeline = nextPipelineId => {
  if (
    selectedStageOrderIsDirty.value &&
    String(nextPipelineId) !== String(selectedStagePipelineId.value)
  ) {
    useAlert(t('CRM.SETTINGS.STAGES.SAVE_OR_DISCARD_ORDER_FIRST'));
    return;
  }

  selectedStagePipelineId.value = String(nextPipelineId || '');
};

const cancelSelectedStageOrder = () => syncSelectedStageOrderDraft();

const saveSelectedStageOrder = async () => {
  const pipelineId = Number(selectedStagePipeline.value?.id);
  if (
    !pipelineId ||
    !selectedStageOrderIsDirty.value ||
    !selectedStageDraftCanSave.value
  )
    return;

  selectedStageOrderSaving.value = true;

  try {
    await referencesStore.saveStageDraft(pipelineId, {
      deleted_stage_ids: selectedStageDeletedIds.value,
      stages: selectedStageOrderRows.value.map(stage => ({
        id: stage.isNew ? undefined : Number(stage.id),
        name: stage.name.trim(),
        color: stage.color,
        active: Boolean(stage.active),
        default: Boolean(stage.default),
        transition_reason_options: normalizedTextValues(
          stage.transitionReasonOptions
        ),
        transition_reason_required: Boolean(stage.transitionReasonRequired),
      })),
      terminal_stages: selectedTerminalStageRows.value.map(stage => ({
        id: Number(stage.id),
        name: stage.name.trim(),
        closing_reason_options: normalizedTextValues(
          stage.closingReasonOptions
        ),
        closing_reason_required: Boolean(stage.closingReasonRequired),
      })),
    });
    syncSelectedStageOrderDraft();
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_SAVE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    selectedStageOrderSaving.value = false;
  }
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
    String(pipelineId) === String(selectedStagePipelineId.value)
      ? [...selectedStageOrderRows.value, ...selectedTerminalStageRows.value]
      : pipelineStagesById(pipelineId),
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
    draftKey: '',
    id: null,
    isNew: false,
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

function openStageDrawer({ pipeline, stage } = {}) {
  if (!canManage.value) return;

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
      draftKey: stage.draftKey || String(stage.id),
      id: stage.id,
      isNew: Boolean(stage.isNew),
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
    stageForm.draftKey = `new-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    stageForm.isNew = true;
  }

  stageDrawerOpen.value = true;
}

const openSelectedStageEditor = async (pipelineId, stageOrCreate = null) => {
  selectStagePipeline(pipelineId);
  if (String(pipelineId) !== String(selectedStagePipelineId.value)) return;

  await nextTick();
  document
    .getElementById('crm-stage-order-editor')
    ?.scrollIntoView({ behavior: 'smooth', block: 'start' });

  if (stageOrCreate === 'create') {
    openStageDrawer({ pipeline: selectedStagePipeline.value });
  } else if (stageOrCreate) {
    const requestedId = Number(stageOrCreate.id || stageOrCreate);
    const stage = [
      ...selectedStageOrderRows.value,
      ...selectedTerminalStageRows.value,
    ].find(item => Number(item.id) === requestedId);
    if (stage) openStageDrawer({ stage });
  }
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
    draftKey: stageForm.draftKey,
    id: stageForm.id,
    isNew: stageForm.isNew,
    name: stageForm.name.trim(),
    pipelineId: Number(stageForm.pipelineId),
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
    transition_reason_options: stageFormTransitionReasonOptions.value,
    transition_reason_required: Boolean(stageForm.transitionReasonRequired),
  };
};

const applyStageFormToDraft = payload => {
  if (String(payload.pipelineId) !== String(selectedStagePipelineId.value)) {
    useAlert(t('CRM.SETTINGS.STAGES.SELECTED_PIPELINE_ONLY'));
    return false;
  }

  if (stageFormIsTerminal.value) {
    const index = selectedTerminalStageRows.value.findIndex(
      stage => Number(stage.id) === Number(payload.id)
    );
    if (index < 0) return false;

    selectedTerminalStageRows.value[index] = {
      ...selectedTerminalStageRows.value[index],
      closingReasonOptions: payload.closing_reason_options,
      closingReasonRequired: payload.closing_reason_required,
      name: payload.name,
    };
    return true;
  }

  const existingIndex = selectedStageOrderRows.value.findIndex(stage =>
    stage.isNew
      ? stage.draftKey === payload.draftKey
      : Number(stage.id) === Number(payload.id)
  );
  const currentStage =
    existingIndex >= 0 ? selectedStageOrderRows.value[existingIndex] : null;
  const nextStage = {
    ...(currentStage || {}),
    active: Boolean(payload.active),
    color: payload.color,
    default: Boolean(payload.default),
    draftKey: payload.draftKey,
    id: payload.isNew ? null : payload.id,
    isNew: Boolean(payload.isNew),
    name: payload.name,
    outcome: 'open',
    pipelineId: Number(payload.pipelineId),
    transitionReasonOptions: payload.transition_reason_options,
    transitionReasonRequired: payload.transition_reason_required,
  };

  if (existingIndex < 0) {
    selectedStageOrderRows.value.push(nextStage);
  } else {
    selectedStageOrderRows.value[existingIndex] = nextStage;
  }

  if (nextStage.default) {
    selectedStageOrderRows.value.forEach(stage => {
      if (stage.draftKey !== nextStage.draftKey) stage.default = false;
    });
  }

  const activeDefault = selectedStageOrderRows.value.some(
    stage => stage.active && stage.default
  );
  if (!activeDefault) {
    const fallback = selectedStageOrderRows.value.find(stage => stage.active);
    if (fallback) fallback.default = true;
  }

  return true;
};

const saveStage = async () => {
  try {
    if (!applyStageFormToDraft(buildStageSavePayload())) return;
    useAlert(t('CRM.SETTINGS.STAGES.DRAFT_UPDATED'));
    stageDrawerOpen.value = false;
    resetStageForm();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const openDeleteStageDialog = async stage => {
  const targetStage =
    stage ||
    (stageForm.id
      ? {
          draftKey: stageForm.draftKey,
          id: stageForm.id,
          isNew: stageForm.isNew,
          name: stageForm.name,
          pipelineId: stageForm.pipelineId,
        }
      : null);

  if (!targetStage || stageDeletionChecking.value) return;

  stagePendingDelete.value = targetStage;
  stageDeletionInfo.value = null;
  if (targetStage.isNew) {
    stageDeletionInfo.value = { canDelete: true, dealCount: 0 };
    stageDeleteDialogRef.value?.open();
    return;
  }

  stageDeletionChecking.value = true;

  try {
    const deletionInfo = await referencesStore.checkStageDeletion(
      targetStage.id
    );
    const activeDraftFallbackExists = selectedStageOrderRows.value.some(
      draftStage =>
        draftStage.active && draftStage.draftKey !== targetStage.draftKey
    );
    stageDeletionInfo.value =
      deletionInfo.blockReason === 'DEFAULT_STAGE_REQUIRES_FALLBACK' &&
      activeDraftFallbackExists
        ? { ...deletionInfo, blockReason: null, canDelete: true }
        : deletionInfo;
  } catch (error) {
    stagePendingDelete.value = null;
    stageDeletionInfo.value = null;
    useAlert(formatErrorMessage(error));
    return;
  } finally {
    stageDeletionChecking.value = false;
  }

  stageDeleteDialogRef.value?.open();
};

const closeDeleteStageDialog = () => {
  stagePendingDelete.value = null;
  stageDeletionInfo.value = null;
};

const deleteStage = async () => {
  if (!stagePendingDelete.value || !stageDeletionInfo.value?.canDelete) return;

  const deletedStage = stagePendingDelete.value;
  selectedStageOrderRows.value = selectedStageOrderRows.value.filter(
    stage => stage.draftKey !== deletedStage.draftKey
  );
  if (!deletedStage.isNew) {
    selectedStageDeletedIds.value = [
      ...new Set([...selectedStageDeletedIds.value, Number(deletedStage.id)]),
    ];
  }

  const defaultStillActive = selectedStageOrderRows.value.some(
    stage => stage.active && stage.default
  );
  if (!defaultStillActive) {
    const fallback = selectedStageOrderRows.value.find(stage => stage.active);
    if (fallback) fallback.default = true;
  }

  stageDeleteDialogRef.value?.close();
  stageDrawerOpen.value = false;
  stagePendingDelete.value = null;
  stageDeletionInfo.value = null;
  resetStageForm();
  useAlert(t('CRM.SETTINGS.STAGES.DRAFT_UPDATED'));
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
      selectedStagePipelineId.value = String(pipeline.id);
      await nextTick();
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
              {{ pipelineEmptyStateMessage }}
            </div>

            <Draggable
              v-if="pipelineRows.length"
              v-model="pipelineRows"
              item-key="id"
              handle=".drag-handle"
              :disabled="
                !canManage || pipelineOrderSaving || pipelineSearchActive
              "
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
                          row.active &&
                          !pipelineOrderSaving &&
                          !pipelineSearchActive
                            ? 'cursor-grab text-n-slate-10 hover:bg-n-alpha-black2 hover:text-n-slate-12 active:cursor-grabbing'
                            : 'cursor-default text-n-slate-8'
                        "
                        :disabled="
                          !row.active ||
                          pipelineOrderSaving ||
                          pipelineSearchActive
                        "
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
                      <span
                        v-for="(stage, index) in getStageRows(row.id)"
                        :key="stage.id"
                        class="inline-flex min-w-0 max-w-full items-center rounded-full bg-n-alpha-black2 px-0.5 py-0.5 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
                      >
                        <button
                          type="button"
                          class="inline-flex min-w-0 max-w-full items-center gap-2 rounded-full border-0 bg-transparent px-2 py-1 text-left"
                          :disabled="!canManage || !row.active"
                          @click="openSelectedStageEditor(row.id, stage.id)"
                        >
                          <span
                            class="inline-flex h-4 min-w-4 shrink-0 items-center justify-center rounded-full border border-black/10 px-1 text-[9px] font-semibold tabular-nums dark:border-white/10"
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
                      </span>

                      <Button
                        v-if="canManage && row.active"
                        size="sm"
                        color="slate"
                        variant="ghost"
                        :label="$t('CRM.SETTINGS.STAGES.REORDER_TITLE')"
                        @click="openSelectedStageEditor(row.id)"
                      />

                      <button
                        v-if="canManage && row.active"
                        type="button"
                        class="inline-flex min-w-0 items-center gap-2 rounded-full border border-dashed border-n-container bg-transparent px-3 py-1.5 text-xs font-medium text-n-slate-10 transition-colors hover:border-n-slate-8 hover:bg-n-alpha-black2 hover:text-n-slate-12"
                        @click="openSelectedStageEditor(row.id, 'create')"
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
            <div class="flex flex-wrap items-center justify-end gap-3">
              <Input
                v-model="pipelineSearchQuery"
                class="w-64 max-w-full"
                size="sm"
                :placeholder="$t('CRM.SETTINGS.PIPELINES.SEARCH_PLACEHOLDER')"
              />
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

        <div id="crm-stage-order-editor">
          <SchedulingFormFieldGroup
            v-if="dealsEnabled"
            :framed="false"
            :title="$t('CRM.SETTINGS.STAGES.REORDER_TITLE')"
            :description="
              $t('CRM.SETTINGS.STAGES.REORDER_DESCRIPTION', {
                name: selectedStagePipeline?.name || '',
              })
            "
          >
            <div
              class="mt-3 grid gap-4 rounded-2xl bg-n-surface-2 p-5 outline outline-1 outline-n-container shadow-sm"
            >
              <div
                class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end"
              >
                <SchedulingSelectField
                  :label="$t('CRM.SETTINGS.STAGES.FORM.PIPELINE')"
                  :model-value="selectedStagePipelineId"
                  :options="activePipelineOptions"
                  :disabled="
                    !activePipelineOptions.length || selectedStageOrderSaving
                  "
                  @update:model-value="selectStagePipeline"
                />
                <Button
                  v-if="canManage && selectedStagePipeline"
                  size="sm"
                  icon="i-lucide-plus"
                  data-test="add-stage-draft"
                  :label="$t('CRM.SETTINGS.STAGES.CREATE_TITLE')"
                  :disabled="selectedStageOrderSaving"
                  @click="openStageDrawer({ pipeline: selectedStagePipeline })"
                />
              </div>

              <p
                v-if="selectedStageOrderIsDirty"
                class="mb-0 rounded-lg bg-n-amber-9/10 px-3 py-2 text-xs text-n-amber-11"
              >
                {{ $t('CRM.SETTINGS.STAGES.ORDER_DRAFT_NOTICE') }}
              </p>

              <template v-if="selectedStagePipeline">
                <Draggable
                  v-model="selectedStageOrderRows"
                  item-key="draftKey"
                  handle=".stage-order-drag-handle"
                  animation="180"
                  ghost-class="pipeline-ghost"
                  class="grid gap-2"
                  :disabled="
                    !canManage ||
                    selectedStageOrderSaving ||
                    !selectedStagePipeline.active
                  "
                >
                  <template #item="{ element: stage, index }">
                    <article
                      class="flex items-center gap-3 rounded-xl border border-n-weak bg-n-surface-1 px-3 py-2.5"
                    >
                      <button
                        type="button"
                        class="stage-order-drag-handle inline-flex size-8 shrink-0 items-center justify-center rounded-md text-n-slate-10 transition-colors hover:bg-n-alpha-black2 hover:text-n-slate-12 disabled:cursor-default disabled:opacity-50"
                        :disabled="
                          !canManage ||
                          selectedStageOrderSaving ||
                          !selectedStagePipeline.active
                        "
                        :title="$t('CRM.SETTINGS.STAGES.REORDER')"
                        :aria-label="
                          $t('CRM.SETTINGS.STAGES.REORDER_STAGE', {
                            name: stage.name,
                          })
                        "
                      >
                        <span
                          class="i-lucide-grip-vertical size-4"
                          aria-hidden="true"
                        />
                      </button>
                      <span
                        class="inline-flex size-8 shrink-0 items-center justify-center rounded-full border border-black/10 text-xs font-semibold tabular-nums dark:border-white/10"
                        :style="stageOrderBadgeStyle(stage.color)"
                      >
                        {{ index + 1 }}
                      </span>
                      <button
                        type="button"
                        data-test="edit-stage"
                        class="min-w-0 flex-1 rounded-md border-0 bg-transparent py-1 text-left focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-weak"
                        :disabled="!canManage || selectedStageOrderSaving"
                        @click="openStageDrawer({ stage })"
                      >
                        <span
                          class="block truncate text-sm font-medium text-n-slate-12"
                        >
                          {{ stage.name }}
                        </span>
                        <span
                          v-if="!stage.active"
                          class="mt-0.5 inline-flex rounded-full bg-n-alpha-black2 px-2 py-0.5 text-[10px] font-medium text-n-slate-10"
                        >
                          {{ $t('CRM.GENERAL.INACTIVE') }}
                        </span>
                        <span
                          v-if="stage.transitionReasonRequired"
                          class="mt-0.5 inline-flex rounded-full bg-n-amber-9/10 px-2 py-0.5 text-[10px] font-medium text-n-amber-11"
                        >
                          {{
                            $t('CRM.SETTINGS.STAGES.TRANSITION_REASON_REQUIRED')
                          }}
                        </span>
                      </button>
                      <span
                        v-if="stage.default"
                        class="shrink-0 rounded-full bg-n-brand/10 px-2 py-1 text-[10px] font-semibold text-n-brand"
                      >
                        {{ $t('CRM.SETTINGS.STAGES.DEFAULT_BADGE') }}
                      </span>
                      <button
                        type="button"
                        data-test="delete-stage-draft"
                        class="inline-flex size-8 shrink-0 items-center justify-center rounded-md text-n-slate-10 hover:bg-n-ruby-9/10 hover:text-n-ruby-11 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-weak disabled:cursor-default disabled:opacity-50"
                        :disabled="
                          !canManage ||
                          selectedStageOrderSaving ||
                          !selectedStagePipeline.active
                        "
                        :title="$t('CRM.SETTINGS.STAGES.DELETE')"
                        :aria-label="
                          $t('CRM.SETTINGS.STAGES.DELETE_STAGE', {
                            name: stage.name,
                          })
                        "
                        @click="openDeleteStageDialog(stage)"
                      >
                        <span
                          class="i-lucide-trash-2 size-4"
                          aria-hidden="true"
                        />
                      </button>
                    </article>
                  </template>
                </Draggable>

                <div
                  v-if="selectedTerminalStageRows.length"
                  class="grid gap-2 border-t border-n-weak pt-3"
                >
                  <p class="mb-0 text-xs font-semibold text-n-slate-10">
                    {{ $t('CRM.SETTINGS.STAGES.LOCKED_TERMINAL_STAGES') }}
                  </p>
                  <button
                    v-for="stage in selectedTerminalStageRows"
                    :key="stage.id"
                    type="button"
                    class="flex w-full items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-surface-1 px-3 py-2.5 text-left"
                    :disabled="!canManage || selectedStageOrderSaving"
                    @click="openStageDrawer({ stage })"
                  >
                    <span
                      class="min-w-0 truncate text-sm font-medium text-n-slate-12"
                    >
                      {{ stage.name }}
                    </span>
                    <span class="shrink-0 text-xs text-n-slate-10">
                      {{
                        stage.outcome === 'won'
                          ? $t('CRM.SETTINGS.STAGES.OUTCOMES.won')
                          : $t('CRM.SETTINGS.STAGES.OUTCOMES.lost')
                      }}
                    </span>
                    <span
                      v-if="stage.closingReasonRequired"
                      class="shrink-0 rounded-full bg-n-amber-9/10 px-2 py-1 text-[10px] font-medium text-n-amber-11"
                    >
                      {{ $t('CRM.SETTINGS.STAGES.CLOSING_REASON_REQUIRED') }}
                    </span>
                  </button>
                </div>

                <div
                  class="flex flex-wrap justify-end gap-2 border-t border-n-weak pt-3"
                >
                  <Button
                    v-if="selectedStageOrderIsDirty"
                    size="sm"
                    color="slate"
                    variant="faded"
                    data-test="cancel-stage-draft"
                    :label="$t('SCHEDULING.GENERAL.CANCEL')"
                    :disabled="selectedStageOrderSaving"
                    @click="cancelSelectedStageOrder"
                  />
                  <Button
                    v-if="canManage"
                    size="sm"
                    data-test="save-stage-draft"
                    :label="$t('CRM.SETTINGS.STAGES.SAVE_ORDER')"
                    :is-loading="selectedStageOrderSaving"
                    :disabled="
                      !selectedStageOrderIsDirty ||
                      !selectedStageDraftCanSave ||
                      selectedStageOrderSaving
                    "
                    @click="saveSelectedStageOrder"
                  />
                </div>
              </template>

              <p v-else class="mb-0 text-sm text-n-slate-11">
                {{ $t('CRM.SETTINGS.STAGES.NO_ACTIVE_PIPELINES') }}
              </p>
            </div>
          </SchedulingFormFieldGroup>
        </div>
      </div>
    </template>

    <SchedulingDrawer
      v-model="stageDrawerOpen"
      width="sm"
      data-test="stage-editor-drawer"
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
          :disabled="Boolean(stageForm.id) || stageForm.isNew"
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
            v-if="!stageFormIsTerminal"
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
              data-test="apply-stage-edit"
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
      data-test="stage-delete-dialog"
      width="md"
      type="alert"
      :title="$t('CRM.SETTINGS.STAGES.DELETE_TITLE')"
      :description="
        stageDeletionInfo?.canDelete
          ? $t('CRM.SETTINGS.STAGES.DELETE_DESCRIPTION', {
              name: stagePendingDelete?.name || '',
            })
          : stageDeletionInfo?.blockReason === 'DEFAULT_STAGE_REQUIRES_FALLBACK'
            ? $t('CRM.ERRORS.DEFAULT_STAGE_REQUIRES_FALLBACK')
            : stageDeletionInfo?.blockReason === 'STANDARD_STAGE_LOCKED'
              ? $t('CRM.ERRORS.STANDARD_STAGE_LOCKED')
              : $t('CRM.ERRORS.STAGE_HAS_DEALS')
      "
      :confirm-button-label="$t('CRM.SETTINGS.STAGES.DELETE_CONFIRM')"
      :is-loading="referencesStore.ui.isSaving || stageDeletionChecking"
      :disable-confirm-button="!stageDeletionInfo?.canDelete"
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
