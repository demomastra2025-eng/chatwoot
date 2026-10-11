<script setup>
import {
  computed,
  onBeforeUnmount,
  onMounted,
  reactive,
  ref,
  watch,
} from 'vue';
import {
  onBeforeRouteLeave,
  onBeforeRouteUpdate,
  useRoute,
  useRouter,
} from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { useAccount } from 'dashboard/composables/useAccount';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import AgentPageHeader from 'dashboard/components-next/captain/agent/AgentPageHeader.vue';
import AgentInstructionTab from 'dashboard/components-next/captain/agent/AgentInstructionTab.vue';
import AgentFollowUpsTab from 'dashboard/components-next/captain/agent/AgentFollowUpsTab.vue';
import AgentCheckTab from 'dashboard/components-next/captain/agent/AgentCheckTab.vue';
import AgentVoiceTab from 'dashboard/components-next/captain/agent/AgentVoiceTab.vue';
import { isVoiceAgent } from 'dashboard/components-next/captain/agent/agentVoice';
import {
  agentInstructionMaxLength,
  buildAgentDraft,
  buildAgentUpdatePayload,
  findAgentModelMetadata,
  isAgentDraftDirty,
  rebaseAgentDraft,
  validateAgentDraft,
} from 'dashboard/components-next/captain/agent/agentDraft';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import { useCaptainChannelMatrixStore } from 'dashboard/store/captain/channelMatrix';

// One AI agent: header (name, description, active, «Проверить», «Сохранить»)
// and the tabs «Инструкция» · «Дожимы» · «Проверка» · «Голос», driven by the
// `tab` query parameter.
const TABS = Object.freeze({
  INSTRUCTION: 'instruction',
  FOLLOW_UPS: 'follow-ups',
  CHECK: 'check',
  VOICE: 'voice',
});

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();
const { checkPermissions, shouldShowPaywall } = usePolicy();
const { isCloudFeatureEnabled } = useAccount();
const captainConfigStore = useCaptainConfigStore();
const channelMatrixStore = useCaptainChannelMatrixStore();

const uiFlags = useMapGetter('captainAssistants/getUIFlags');
const inboxes = useMapGetter('inboxes/getInboxes');

const isAdmin = computed(() => checkPermissions(['administrator']));
const isPaywalled = computed(
  () => shouldShowPaywall?.(FEATURE_FLAGS.CAPTAIN) === true
);
const assistantId = computed(() => Number(route.params.assistantId));
const assistant = computed(
  () => store.getters['captainAssistants/getRecord'](assistantId.value) || {}
);
const hasAssistant = computed(() => Boolean(assistant.value?.id));
const isFetching = computed(
  () => Boolean(uiFlags.value?.fetchingItem) && !hasAssistant.value
);

// ---- Draft ---------------------------------------------------------------
const baseDraft = ref(null);
const draft = ref(null);
const draftAssistantId = ref(null);
const isSaving = ref(false);

watch(
  assistant,
  record => {
    if (!record?.id) return;
    const nextBase = buildAgentDraft(record);
    if (draftAssistantId.value !== record.id || !draft.value) {
      draftAssistantId.value = record.id;
      baseDraft.value = nextBase;
      draft.value = { ...nextBase };
      return;
    }
    draft.value = rebaseAgentDraft(baseDraft.value, nextBase, draft.value);
    baseDraft.value = nextBase;
  },
  { immediate: true }
);

const modelMetadata = computed(() => {
  if (!draft.value) return {};
  const platformModelId =
    captainConfigStore.getSelectedModelForFeature('assistant') || '';
  return findAgentModelMetadata({
    models: captainConfigStore.getModelsForFeature('assistant') || [],
    modelId: draft.value.model || platformModelId,
    assistant: assistant.value,
  });
});

const isDirty = computed(
  () =>
    isAdmin.value &&
    isAgentDraftDirty(baseDraft.value, draft.value, modelMetadata.value)
);
const validation = computed(() =>
  draft.value
    ? validateAgentDraft(draft.value, baseDraft.value)
    : { valid: false, errors: {} }
);
const instructionMaxLength = computed(() =>
  agentInstructionMaxLength(baseDraft.value)
);

const save = async () => {
  if (!isAdmin.value || !draft.value || isSaving.value) return;
  if (!isDirty.value || !validation.value.valid) return;

  const sentDraft = { ...draft.value };
  const payload = buildAgentUpdatePayload(
    baseDraft.value,
    sentDraft,
    modelMetadata.value
  );
  if (!Object.keys(payload).length) {
    baseDraft.value = sentDraft;
    return;
  }

  isSaving.value = true;
  try {
    const saved = await store.dispatch('captainAssistants/update', {
      id: assistantId.value,
      ...payload,
    });
    const record = saved?.id ? saved : assistant.value;
    const savedBase = buildAgentDraft(record);
    // Keep anything typed while the request was running.
    draft.value = rebaseAgentDraft(sentDraft, savedBase, draft.value);
    baseDraft.value = savedBase;
    useAlert(t('CAPTAIN.AGENT_PAGE.SAVED'));
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.ASSISTANTS.EDIT.ERROR_MESSAGE'));
  } finally {
    isSaving.value = false;
  }
};

// ---- Tabs ----------------------------------------------------------------
const showFollowUpsTab = computed(() =>
  isCloudFeatureEnabled(FEATURE_FLAGS.CAPTAIN_V2)
);
const showVoiceTab = computed(
  () => hasAssistant.value && isVoiceAgent(assistant.value, inboxes.value)
);
const followUpsEnabled = computed(
  () => assistant.value?.config?.follow_up_settings?.enabled === true
);

const tabs = computed(() => [
  { key: TABS.INSTRUCTION, label: t('CAPTAIN.AGENT_PAGE.TABS.INSTRUCTION') },
  ...(showFollowUpsTab.value
    ? [
        {
          key: TABS.FOLLOW_UPS,
          label: `${t('CAPTAIN.AGENT_PAGE.TABS.FOLLOW_UPS')} · ${
            followUpsEnabled.value
              ? t('CAPTAIN.AGENT_PAGE.TABS.FOLLOW_UPS_ON')
              : t('CAPTAIN.AGENT_PAGE.TABS.FOLLOW_UPS_OFF')
          }`,
        },
      ]
    : []),
  { key: TABS.CHECK, label: t('CAPTAIN.AGENT_PAGE.TABS.CHECK') },
  ...(showVoiceTab.value
    ? [{ key: TABS.VOICE, label: t('CAPTAIN.AGENT_PAGE.TABS.VOICE') }]
    : []),
]);

const activeTab = computed(() => {
  const requested = String(route.query.tab || '');
  return tabs.value.some(tab => tab.key === requested)
    ? requested
    : TABS.INSTRUCTION;
});
const activeTabIndex = computed(() =>
  Math.max(
    tabs.value.findIndex(tab => tab.key === activeTab.value),
    0
  )
);

// Tabs mount on first visit and stay alive (v-show) to keep their state.
const visitedTabs = reactive({});
watch(
  activeTab,
  key => {
    visitedTabs[key] = true;
  },
  { immediate: true }
);

const setTab = key => {
  const { tab: _tab, ...query } = route.query;
  if (key && key !== TABS.INSTRUCTION) query.tab = key;
  router.replace({ name: route.name, params: route.params, query });
};

const handleTabChanged = tab => setTab(tab?.key);

// ---- Unsaved changes -----------------------------------------------------
const tabDirty = reactive({ [TABS.FOLLOW_UPS]: false, [TABS.VOICE]: false });
const setTabDirty = (key, value) => {
  tabDirty[key] = Boolean(value);
};

const hasUnsavedChanges = computed(
  () => isDirty.value || tabDirty[TABS.FOLLOW_UPS] || tabDirty[TABS.VOICE]
);

let skipLeaveConfirm = false;

const confirmLeave = () => {
  if (skipLeaveConfirm || !hasUnsavedChanges.value) return true;
  // eslint-disable-next-line no-alert
  return window.confirm(t('CAPTAIN.AGENT_PAGE.LEAVE_CONFIRM'));
};

onBeforeRouteLeave(() => confirmLeave());

// Switching tabs only changes the query: no confirmation. Opening another
// agent in the same page instance does ask.
onBeforeRouteUpdate((to, from) => {
  if (String(to.params.assistantId) === String(from.params.assistantId)) {
    return true;
  }
  if (!confirmLeave()) return false;
  tabDirty[TABS.FOLLOW_UPS] = false;
  tabDirty[TABS.VOICE] = false;
  return true;
});

const handleBeforeUnload = event => {
  if (!hasUnsavedChanges.value) return;
  event.preventDefault();
  event.returnValue = '';
};

const handleDeleted = () => {
  skipLeaveConfirm = true;
  router.push({
    name: 'captain_agents_index',
    params: { accountId: route.params.accountId },
  });
};

// ---- Loading -------------------------------------------------------------
watch(
  assistantId,
  async id => {
    Object.keys(visitedTabs).forEach(key => {
      if (key !== activeTab.value) delete visitedTabs[key];
    });
    if (!id || store.getters['captainAssistants/getRecord'](id)?.id) return;
    try {
      await store.dispatch('captainAssistants/show', id);
    } catch {
      useAlert(t('CAPTAIN.ASSISTANTS.EDIT.NOT_FOUND'));
    }
  },
  { immediate: true }
);

onMounted(() => {
  window.addEventListener('beforeunload', handleBeforeUnload);
  captainConfigStore.fetch();
  if (isAdmin.value) channelMatrixStore.fetch();
});

onBeforeUnmount(() => {
  window.removeEventListener('beforeunload', handleBeforeUnload);
});
</script>

<template>
  <PageLayout
    :is-fetching="isFetching"
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
    :show-pagination-footer="false"
    :show-know-more="false"
    content-width="full"
  >
    <template #header="{ showPaywall }">
      <AgentPageHeader
        v-if="!showPaywall && hasAssistant && draft"
        v-model:draft="draft"
        :assistant="assistant"
        :errors="validation.errors"
        :show-errors="isDirty"
        :can-edit="isAdmin"
        :is-dirty="isDirty"
        :is-valid="validation.valid"
        :is-saving="isSaving"
        @save="save"
        @check="setTab(TABS.CHECK)"
        @deleted="handleDeleted"
      />
    </template>

    <template #subHeader>
      <div v-if="hasAssistant && !isPaywalled" class="pb-3 pt-2">
        <TabBar
          active-text-class="text-n-slate-12 scale-100"
          :tabs="tabs"
          :initial-active-tab="activeTabIndex"
          data-test="agent-tabs"
          @tab-changed="handleTabChanged"
        />
      </div>
    </template>

    <template #body>
      <div v-if="hasAssistant && draft" :key="assistant.id" class="pb-8">
        <AgentInstructionTab
          v-if="visitedTabs[TABS.INSTRUCTION]"
          v-show="activeTab === TABS.INSTRUCTION"
          v-model:draft="draft"
          :assistant="assistant"
          :errors="validation.errors"
          :show-errors="isDirty"
          :can-edit="isAdmin"
          :instruction-max-length="instructionMaxLength"
          @open-follow-ups="setTab(TABS.FOLLOW_UPS)"
        />
        <AgentFollowUpsTab
          v-if="showFollowUpsTab && visitedTabs[TABS.FOLLOW_UPS]"
          v-show="activeTab === TABS.FOLLOW_UPS"
          :assistant="assistant"
          :can-edit="isAdmin"
          @dirty-change="setTabDirty(TABS.FOLLOW_UPS, $event)"
          @saved="setTabDirty(TABS.FOLLOW_UPS, false)"
        />
        <AgentCheckTab
          v-if="visitedTabs[TABS.CHECK]"
          v-show="activeTab === TABS.CHECK"
          :assistant="assistant"
          :account-id="route.params.accountId"
        />
        <AgentVoiceTab
          v-if="showVoiceTab && visitedTabs[TABS.VOICE]"
          v-show="activeTab === TABS.VOICE"
          :assistant="assistant"
          :can-edit="isAdmin"
          @dirty-change="setTabDirty(TABS.VOICE, $event)"
          @saved="setTabDirty(TABS.VOICE, false)"
        />
      </div>
    </template>

    <template #paywall>
      <CaptainPaywall />
    </template>
  </PageLayout>
</template>
