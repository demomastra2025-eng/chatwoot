<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import NextSelect from 'dashboard/components-next/select/Select.vue';
import Button from 'next/button/Button.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import {
  CONVERSATION_ASSIGNEE_VISIBILITY_KEY,
  CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
  CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS,
  CONVERSATION_PIPELINES_VISIBILITY_KEY,
  CONVERSATION_SIDEBAR_VISIBILITY_ITEMS,
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
  buildSidebarVisibilityState,
  getConversationSidebarHiddenItems,
  getConversationSidebarHiddenItemsFromState,
  getSidebarHiddenItems,
} from 'dashboard/components-next/sidebar/sidebarVisibility';
import {
  CONVERSATION_PIPELINE_VISIBILITY_SETTINGS_KEY,
  buildConversationPipelineVisibilityDraft,
  resolveActiveConversationPipelines,
  serializeConversationPipelineVisibility,
} from 'dashboard/components-next/sidebar/conversationPipelineVisibility';

const CONVERSATION_ASSIGNEE_ITEM_VISIBILITY_KEYS = Object.freeze([
  'Conversation:Assignee:all',
  'Conversation:Assignee:me',
  'Conversation:Assignee:unassigned',
]);

// All / Mine / Unassigned: the group switch locks the list to All when it is
// off; while it is on, each list can still be hidden on its own (as the old
// company Visibility page saved them).
const ASSIGNEE_GROUP = Object.freeze({
  key: 'assignee',
  parentKey: CONVERSATION_ASSIGNEE_VISIBILITY_KEY,
  labelKey: 'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.ASSIGNEE',
  descriptionKey: 'CONVERSATION_WORKFLOW.VISIBILITY.DESCRIPTIONS.ASSIGNEE',
  // Explains that switching the group off keeps the list on All.
  showDescription: true,
  itemKeys: [...CONVERSATION_ASSIGNEE_ITEM_VISIBILITY_KEYS],
});

const PRIMARY_NAVIGATION_ITEMS = Object.freeze([
  {
    key: 'folders',
    visibilityKey: 'Conversation:Folders',
    labelKey: 'SIDEBAR.CUSTOM_VIEWS_FOLDER',
  },
  {
    key: 'teams',
    visibilityKey: 'Conversation:Teams',
    labelKey: 'SIDEBAR.TEAMS',
  },
  {
    key: 'labels',
    visibilityKey: 'Conversation:Labels',
    labelKey: 'SIDEBAR.LABELS',
  },
]);

// Statuses are not part of the sidebar: they are picked in the conversation
// list header.
const VISIBILITY_GROUPS = Object.freeze([
  {
    key: 'pipeline',
    parentKey: CONVERSATION_PIPELINES_VISIBILITY_KEY,
    labelKey: 'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.PIPELINE',
    descriptionKey: 'CONVERSATION_WORKFLOW.VISIBILITY.DESCRIPTIONS.PIPELINE',
    featureFlag: FEATURE_FLAGS.CRM_DEALS,
    itemKeys: [],
  },
  {
    key: 'appointments',
    parentKey: CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
    labelKey: 'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.APPOINTMENTS',
    descriptionKey:
      'CONVERSATION_WORKFLOW.VISIBILITY.DESCRIPTIONS.APPOINTMENTS',
    featureFlag: FEATURE_FLAGS.SCHEDULING,
    itemKeys: [
      ...Object.values(CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS),
    ],
  },
]);

const { t } = useI18n();
const { accountId, currentAccount, updateAccount } = useAccount();
const crmReferencesStore = useCrmReferencesStore();
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const visibilityDraft = ref({});
const pipelineVisibilityDraft = ref({});
const expandedGroupKey = ref(null);
const pipelinesLoadFailed = ref(false);
const isSaving = ref(false);

const conversationVisibilityItemKeys = new Set(
  CONVERSATION_SIDEBAR_VISIBILITY_ITEMS.map(item => item.key)
);
const conversationVisibilityItemsByKey = new Map(
  CONVERSATION_SIDEBAR_VISIBILITY_ITEMS.map(item => [item.key, item])
);

const savedConversationHiddenItems = computed(() =>
  getConversationSidebarHiddenItems(currentAccount.value?.settings || {})
);
const draftConversationHiddenItems = computed(() =>
  getConversationSidebarHiddenItemsFromState(visibilityDraft.value)
);
const hasCrmDeals = computed(() =>
  isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_DEALS)
);
const activePipelines = computed(() =>
  resolveActiveConversationPipelines(crmReferencesStore.pipelines)
);
const pipelineOptions = computed(() =>
  activePipelines.value
    .filter(pipeline => pipeline.stages.length > 0)
    .map(pipeline => ({
      label: pipeline.name,
      value: pipeline.id,
    }))
);
const savedPipelineVisibility = computed(() =>
  serializeConversationPipelineVisibility(
    buildConversationPipelineVisibilityDraft(
      currentAccount.value?.settings || {},
      activePipelines.value
    ),
    activePipelines.value
  )
);
const draftPipelineVisibility = computed(() =>
  serializeConversationPipelineVisibility(
    pipelineVisibilityDraft.value,
    activePipelines.value
  )
);
const hasConversationVisibilityChanges = computed(
  () =>
    JSON.stringify(savedConversationHiddenItems.value) !==
    JSON.stringify(draftConversationHiddenItems.value)
);
const hasPipelineVisibilityChanges = computed(
  () =>
    hasCrmDeals.value &&
    JSON.stringify(savedPipelineVisibility.value) !==
      JSON.stringify(draftPipelineVisibility.value)
);
const hasChanges = computed(
  () =>
    hasConversationVisibilityChanges.value || hasPipelineVisibilityChanges.value
);
const visibilityDraftInitialized = ref(false);
const pipelineVisibilityDraftInitialized = ref(false);

const withGroupItems = group => ({
  ...group,
  items: group.itemKeys
    .map(key => conversationVisibilityItemsByKey.get(key))
    .filter(Boolean),
});

const groupedVisibilityItems = computed(() =>
  VISIBILITY_GROUPS.filter(
    group =>
      !group.featureFlag ||
      isFeatureEnabledonAccount.value(accountId.value, group.featureFlag)
  ).map(withGroupItems)
);

// Rows in page order: the assignee lists first, then the single switches
// (folders, teams, tags), then the configurable groups.
const navigationRows = computed(() => [
  { ...withGroupItems(ASSIGNEE_GROUP), isGroup: true },
  ...PRIMARY_NAVIGATION_ITEMS.map(item => ({ ...item, isGroup: false })),
  ...groupedVisibilityItems.value.map(group => ({ ...group, isGroup: true })),
]);

const switchId = itemKey =>
  `conversation-visibility-${itemKey
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')}`;

const visibilityLabel = item =>
  item.labelKey
    ? // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys -- fixed visibility whitelist
      t(item.labelKey)
    : item.key;

const groupLabel = group =>
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys -- fixed visibility groups
  t(group.labelKey);

const groupDescription = group =>
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys -- fixed visibility groups
  t(group.descriptionKey);

const isPrimaryNavigationItemEnabled = item =>
  visibilityDraft.value[item.visibilityKey] !== false;

const togglePrimaryNavigationItem = item => {
  visibilityDraft.value[item.visibilityKey] =
    !isPrimaryNavigationItemEnabled(item);
};

const isGroupEnabled = group =>
  visibilityDraft.value[group.parentKey] !== false;

const isItemDisabled = group => !isGroupEnabled(group);

const toggleGroup = group => {
  const isEnabled = !isGroupEnabled(group);
  visibilityDraft.value[group.parentKey] = isEnabled;
  // Switching the assignee lists back on shows All, Mine and Unassigned.
  if (group.key === ASSIGNEE_GROUP.key) {
    CONVERSATION_ASSIGNEE_ITEM_VISIBILITY_KEYS.forEach(key => {
      visibilityDraft.value[key] = true;
    });
  }
  if (!isEnabled && expandedGroupKey.value === group.key) {
    expandedGroupKey.value = null;
  }
};

const isGroupExpanded = group => expandedGroupKey.value === group.key;
const toggleGroupExpansion = group => {
  if (!isGroupEnabled(group)) return;
  expandedGroupKey.value = isGroupExpanded(group) ? null : group.key;
};
const groupActionLabel = group =>
  isGroupExpanded(group)
    ? t('CONVERSATION_WORKFLOW.VISIBILITY.SUMMARY.COLLAPSE')
    : t('CONVERSATION_WORKFLOW.VISIBILITY.SUMMARY.CONFIGURE');

const pipelineId = pipeline => String(pipeline.id);
const stageId = stage => String(stage.id);
const pipelineState = pipeline =>
  pipelineVisibilityDraft.value[pipelineId(pipeline)];
const isPipelineEnabled = pipeline => pipelineState(pipeline)?.enabled === true;

const selectedPipeline = computed(() =>
  activePipelines.value.find(pipeline => isPipelineEnabled(pipeline))
);

const setSelectedPipeline = selectedId => {
  const selected = activePipelines.value.find(
    pipeline => String(pipeline.id) === String(selectedId)
  );
  if (!selected?.stages.length) return;

  activePipelines.value.forEach(pipeline => {
    const state = pipelineState(pipeline);
    if (state) state.enabled = pipeline.id === selected.id;
  });

  const state = pipelineState(selected);
  if (state && !Object.values(state.stages).some(Boolean)) {
    Object.keys(state.stages).forEach(key => {
      state.stages[key] = true;
    });
  }
};
const selectedPipelineId = computed({
  get: () => selectedPipeline.value?.id || '',
  set: value => setSelectedPipeline(value),
});

const enabledStageCount = pipeline =>
  Object.values(pipelineState(pipeline)?.stages || {}).filter(Boolean).length;

const groupSummary = group => {
  if (!isGroupEnabled(group)) {
    return t('CONVERSATION_WORKFLOW.VISIBILITY.SUMMARY.HIDDEN');
  }

  if (group.key === 'pipeline') {
    if (!selectedPipeline.value) {
      return t('CONVERSATION_WORKFLOW.VISIBILITY.SUMMARY.PIPELINE_EMPTY');
    }

    return t('CONVERSATION_WORKFLOW.VISIBILITY.SUMMARY.PIPELINE', {
      pipeline: selectedPipeline.value.name,
      visible: enabledStageCount(selectedPipeline.value),
      total: selectedPipeline.value.stages.length,
    });
  }

  const visible = group.items.filter(
    item => visibilityDraft.value[item.key] !== false
  ).length;
  const summary = {
    visible,
    total: group.items.length,
  };
  return group.key === ASSIGNEE_GROUP.key
    ? t('CONVERSATION_WORKFLOW.VISIBILITY.SUMMARY.LISTS', summary)
    : t('CONVERSATION_WORKFLOW.VISIBILITY.SUMMARY.STATUSES', summary);
};

// At least one stage of the main pipeline stays visible.
const isStageDisabled = (group, pipeline, stage) =>
  isItemDisabled(group) ||
  !isPipelineEnabled(pipeline) ||
  (pipelineState(pipeline)?.stages?.[stageId(stage)] === true &&
    enabledStageCount(pipeline) === 1);

const setStageVisibility = (group, pipeline, stage, enabled) => {
  if (isStageDisabled(group, pipeline, stage)) return;
  pipelineState(pipeline).stages[stageId(stage)] = enabled;
};

const loadPipelines = async () => {
  if (!hasCrmDeals.value) return;

  try {
    await crmReferencesStore.loadPipelines();
    pipelinesLoadFailed.value = false;
  } catch {
    pipelinesLoadFailed.value = true;
  }
};

const saveVisibility = async () => {
  const nonConversationHiddenItems = getSidebarHiddenItems(
    currentAccount.value?.settings || {}
  ).filter(key => !conversationVisibilityItemKeys.has(key));

  isSaving.value = true;
  try {
    const payload = {
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
        ...nonConversationHiddenItems,
        ...draftConversationHiddenItems.value,
      ],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    };
    // Never overwrite the saved pipeline choice while pipelines are unknown.
    if (hasCrmDeals.value && activePipelines.value.length) {
      payload[CONVERSATION_PIPELINE_VISIBILITY_SETTINGS_KEY] =
        draftPipelineVisibility.value;
    }

    await updateAccount(payload);
    useAlert(t('CONVERSATION_WORKFLOW.VISIBILITY.SAVE.SUCCESS'));
  } catch {
    useAlert(t('GENERAL_SETTINGS.UPDATE.ERROR'));
  } finally {
    isSaving.value = false;
  }
};

const reconcilePipelineVisibilityDraft = (currentDraft, hydratedDraft) => {
  const selectedDraftPipelineId = Object.keys(hydratedDraft).find(
    id => currentDraft[id]?.enabled === true
  );

  return Object.fromEntries(
    Object.entries(hydratedDraft).map(([id, hydratedPipeline]) => {
      const currentPipeline = currentDraft[id];
      const stages = Object.fromEntries(
        Object.entries(hydratedPipeline.stages).map(
          ([stageVisibilityId, enabled]) => [
            stageVisibilityId,
            currentPipeline?.stages?.[stageVisibilityId] ?? enabled,
          ]
        )
      );

      return [
        id,
        {
          enabled: selectedDraftPipelineId
            ? id === selectedDraftPipelineId
            : hydratedPipeline.enabled,
          stages,
        },
      ];
    })
  );
};

watch(
  [
    () => currentAccount.value?.settings?.[SIDEBAR_VISIBILITY_UI_SETTINGS_KEY],
    () =>
      currentAccount.value?.settings?.[
        SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY
      ],
  ],
  () => {
    if (
      visibilityDraftInitialized.value &&
      hasConversationVisibilityChanges.value
    ) {
      return;
    }
    visibilityDraft.value = buildSidebarVisibilityState(
      currentAccount.value?.settings || {}
    );
    visibilityDraftInitialized.value = true;
  },
  { deep: true, immediate: true }
);

watch(
  () =>
    currentAccount.value?.settings?.[
      CONVERSATION_PIPELINE_VISIBILITY_SETTINGS_KEY
    ],
  () => {
    if (
      pipelineVisibilityDraftInitialized.value &&
      hasPipelineVisibilityChanges.value
    ) {
      return;
    }
    pipelineVisibilityDraft.value = buildConversationPipelineVisibilityDraft(
      currentAccount.value?.settings || {},
      crmReferencesStore.pipelines
    );
    pipelineVisibilityDraftInitialized.value = true;
  },
  { deep: true, immediate: true }
);

watch(
  () => crmReferencesStore.pipelines,
  pipelines => {
    const hydratedDraft = buildConversationPipelineVisibilityDraft(
      currentAccount.value?.settings || {},
      pipelines
    );
    pipelineVisibilityDraft.value = reconcilePipelineVisibilityDraft(
      pipelineVisibilityDraft.value,
      hydratedDraft
    );
  },
  { deep: true }
);

onMounted(() => {
  if (
    hasCrmDeals.value &&
    !crmReferencesStore.pipelines.length &&
    !crmReferencesStore.ui?.isLoadingPipelines
  ) {
    loadPipelines();
  }
});
</script>

<template>
  <SettingsLayout :no-records-found="false" class="gap-8">
    <template #header>
      <BaseSettingsHeader
        :title="$t('CONVERSATION_WORKFLOW.VISIBILITY.HEADER.TITLE')"
        :description="$t('CONVERSATION_WORKFLOW.VISIBILITY.HEADER.DESCRIPTION')"
        feature-name="conversation-visibility"
      />
    </template>

    <template #body>
      <div class="flex flex-col">
        <div
          data-testid="conversation-primary-navigation"
          class="flex flex-col divide-y divide-n-weak/50 py-4"
        >
          <template v-for="row in navigationRows" :key="row.key">
            <label
              v-if="!row.isGroup"
              :data-testid="`conversation-navigation-item-${row.key}`"
              class="flex items-center justify-between gap-3 py-3"
            >
              <span class="min-w-0">
                <span class="block text-sm font-medium text-n-slate-12">
                  {{ groupLabel(row) }}
                </span>
                <span
                  v-if="row.descriptionKey"
                  class="mt-0.5 block text-xs text-n-slate-11"
                >
                  {{ groupDescription(row) }}
                </span>
              </span>
              <Switch
                :id="switchId(row.visibilityKey)"
                :model-value="isPrimaryNavigationItemEnabled(row)"
                @update:model-value="togglePrimaryNavigationItem(row)"
              />
            </label>
            <div
              v-else
              :data-testid="`conversation-navigation-group-${row.key}`"
              class="py-3"
            >
              <div class="flex items-center justify-between gap-3">
                <button
                  type="button"
                  class="min-w-0 flex-1 text-left"
                  :disabled="!isGroupEnabled(row)"
                  :aria-expanded="isGroupExpanded(row)"
                  @click="toggleGroupExpansion(row)"
                >
                  <span class="block text-sm font-medium text-n-slate-12">
                    {{ groupLabel(row) }}
                  </span>
                  <span
                    v-if="row.showDescription"
                    class="mt-0.5 block text-xs text-n-slate-11"
                  >
                    {{ groupDescription(row) }}
                  </span>
                  <span
                    class="mt-0.5 flex flex-wrap items-center gap-x-1.5 text-xs text-n-slate-11"
                  >
                    <span>{{ groupSummary(row) }}</span>
                    <span
                      v-if="isGroupEnabled(row)"
                      class="font-medium text-n-brand"
                    >
                      {{ groupActionLabel(row) }}
                    </span>
                  </span>
                </button>
                <Switch
                  :id="switchId(row.parentKey)"
                  class="shrink-0"
                  :model-value="isGroupEnabled(row)"
                  @update:model-value="toggleGroup(row)"
                />
              </div>

              <div
                v-if="isGroupEnabled(row) && isGroupExpanded(row)"
                class="pb-2 pl-4 pt-4 md:pl-6"
              >
                <div v-if="row.key === 'pipeline'" class="grid max-w-2xl gap-5">
                  <p
                    v-if="crmReferencesStore.ui?.isLoadingPipelines"
                    class="text-body-main text-n-slate-11"
                  >
                    {{
                      t(
                        'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.PIPELINES_LOADING'
                      )
                    }}
                  </p>
                  <div
                    v-else-if="pipelinesLoadFailed"
                    data-testid="conversation-navigation-pipelines-error"
                    class="flex items-center justify-between gap-3 rounded-lg bg-n-amber-2 px-3 py-2 text-sm text-n-slate-12"
                  >
                    <span>
                      {{
                        t(
                          'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.PIPELINES_ERROR'
                        )
                      }}
                    </span>
                    <button
                      type="button"
                      class="shrink-0 font-medium text-n-brand hover:underline"
                      @click="loadPipelines"
                    >
                      {{ t('CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.RETRY') }}
                    </button>
                  </div>
                  <p
                    v-else-if="!pipelineOptions.length"
                    class="text-body-main text-n-slate-11"
                  >
                    {{
                      t(
                        'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.PIPELINES_EMPTY'
                      )
                    }}
                  </p>
                  <template v-else>
                    <label
                      class="grid max-w-md gap-2 text-sm font-medium text-n-slate-12"
                      :for="switchId('primary-pipeline')"
                    >
                      {{
                        t(
                          'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.PRIMARY_PIPELINE'
                        )
                      }}
                      <NextSelect
                        :id="switchId('primary-pipeline')"
                        v-model="selectedPipelineId"
                        class="w-full"
                        :options="pipelineOptions"
                        :placeholder="
                          t(
                            'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.PRIMARY_PIPELINE_PLACEHOLDER'
                          )
                        "
                      />
                    </label>

                    <div v-if="selectedPipeline" class="grid gap-2">
                      <span class="text-sm font-medium text-n-slate-12">
                        {{ t('CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.STAGES') }}
                      </span>
                      <div class="flex flex-col divide-y divide-n-weak/50">
                        <div
                          v-for="stage in selectedPipeline.stages"
                          :key="stage.id"
                          class="flex cursor-pointer items-center justify-between gap-3 py-3"
                          :class="{
                            'cursor-default opacity-60': isStageDisabled(
                              row,
                              selectedPipeline,
                              stage
                            ),
                          }"
                          @click="
                            setStageVisibility(
                              row,
                              selectedPipeline,
                              stage,
                              !pipelineState(selectedPipeline).stages[
                                stageId(stage)
                              ]
                            )
                          "
                        >
                          <span
                            class="min-w-0 truncate text-sm text-n-slate-12"
                          >
                            {{ stage.name }}
                          </span>
                          <Switch
                            :id="
                              switchId(
                                `pipeline-${selectedPipeline.id}-stage-${stage.id}`
                              )
                            "
                            :model-value="
                              pipelineState(selectedPipeline).stages[
                                stageId(stage)
                              ]
                            "
                            :disabled="
                              isStageDisabled(row, selectedPipeline, stage)
                            "
                            @update:model-value="
                              value =>
                                setStageVisibility(
                                  row,
                                  selectedPipeline,
                                  stage,
                                  value
                                )
                            "
                            @click.stop
                          />
                        </div>
                      </div>
                    </div>
                  </template>
                </div>

                <div v-else class="flex flex-col divide-y divide-n-weak/50">
                  <label
                    v-for="item in row.items"
                    :key="item.key"
                    class="flex items-center justify-between gap-3 py-3"
                  >
                    <span class="min-w-0 text-sm text-n-slate-12">
                      {{ visibilityLabel(item) }}
                    </span>
                    <Switch
                      :id="switchId(item.key)"
                      v-model="visibilityDraft[item.key]"
                    />
                  </label>
                </div>
              </div>
            </div>
          </template>
        </div>

        <div class="flex justify-end border-t border-n-weak py-6">
          <Button
            :label="t('CONVERSATION_WORKFLOW.VISIBILITY.SAVE.BUTTON')"
            color="slate"
            variant="outline"
            size="sm"
            :disabled="!hasChanges || isSaving"
            :is-loading="isSaving"
            @click="saveVisibility"
          />
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
