<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { useAlert } from 'dashboard/composables';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useCaptainChannelMatrixStore } from 'dashboard/store/captain/channelMatrix';
import { agentChannelSummary } from 'dashboard/helper/captainChannelMatrix';

import Button from 'dashboard/components-next/button/Button.vue';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import AgentGalleryCard from 'dashboard/components-next/captain/agent/AgentGalleryCard.vue';
import AgentNewTile from 'dashboard/components-next/captain/agent/AgentNewTile.vue';
import CreateAgentDialog from 'dashboard/components-next/captain/agent/CreateAgentDialog.vue';
import { useAgentActiveToggle } from 'dashboard/components-next/captain/agent/useAgentActiveToggle';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();
const { checkPermissions, shouldShowPaywall } = usePolicy();
const matrixStore = useCaptainChannelMatrixStore();
const { setActive, isToggling } = useAgentActiveToggle();

const createDialogRef = ref(null);
const hasLoaded = ref(false);
const isBulkToggling = ref(false);

const uiFlags = useMapGetter('captainAssistants/getUIFlags');
// getRecords already hides the internal assistants: only AI agents are listed.
const assistants = useMapGetter('captainAssistants/getRecords');
const inboxes = useMapGetter('inboxes/getInboxes');

const isAdmin = computed(() => checkPermissions(['administrator']));
const matrix = computed(() => matrixStore.getMatrix || null);
const mainAgentId = computed(() =>
  Number(matrix.value?.default_main_assistant_id || 0)
);

const agents = computed(() =>
  [...(assistants.value || [])].sort((first, second) => {
    const firstActive = first.active !== false;
    const secondActive = second.active !== false;
    if (firstActive !== secondActive) return firstActive ? -1 : 1;

    return String(first.name || '').localeCompare(
      String(second.name || ''),
      undefined,
      { sensitivity: 'base' }
    );
  })
);

const toggleableAgents = computed(() =>
  agents.value.filter(agent => Number(agent.id) !== mainAgentId.value)
);

const hasActiveToggleableAgents = computed(() =>
  toggleableAgents.value.some(agent => agent.active !== false)
);

const isFetching = computed(
  () =>
    !agents.value.length &&
    (Boolean(uiFlags.value?.fetchingList) || !hasLoaded.value)
);

const buildStats = assistant => {
  const summary = agentChannelSummary({
    assistant,
    matrix: matrix.value,
    inboxes: inboxes.value || [],
  });
  if (!summary) return null;

  // Without the matrix (non-admins) an agent on «all channels» has no exact
  // channel list, so the card says «all channels» instead of a number.
  const memberCountUnknown = !matrix.value && summary.scope === 'all';
  const memberCount = summary.memberInboxIds?.length || 0;

  return {
    scope: summary.scope,
    mainCount: summary.mainInboxIds?.length || 0,
    memberCount: memberCountUnknown ? null : memberCount,
  };
};

const statsById = computed(() =>
  Object.fromEntries(agents.value.map(agent => [agent.id, buildStats(agent)]))
);

const refreshMatrix = () => {
  if (isAdmin.value) matrixStore.fetch({ force: true });
};

const openAgent = agent => {
  router.push({
    name: 'captain_agent_show',
    params: { accountId: route.params.accountId, assistantId: agent.id },
  });
};

const handleToggleActive = async (agent, active) => {
  if (!active && mainAgentId.value === Number(agent.id)) return;
  const saved = await setActive(agent, active);
  if (saved) refreshMatrix();
};

const handleToggleAllAgents = async () => {
  if (!isAdmin.value || isBulkToggling.value || !toggleableAgents.value.length)
    return;
  const nextActive = !hasActiveToggleableAgents.value;
  const targets = toggleableAgents.value.filter(
    agent => (agent.active !== false) !== nextActive
  );
  if (!targets.length) return;

  isBulkToggling.value = true;
  try {
    await Promise.all(targets.map(agent => setActive(agent, nextActive)));
    refreshMatrix();
  } finally {
    isBulkToggling.value = false;
  }
};

const makeMain = async agent => {
  if (!agent.active || !isAdmin.value) return;
  const result = await matrixStore.save({
    default_main_assistant_id: agent.id,
  });
  if (!result.ok) useAlert(t('CAPTAIN.CHANNEL_MATRIX.SAVE_ERROR'));
};

const openCreateDialog = () => {
  createDialogRef.value?.dialogRef?.open();
};

const handleCreated = agent => {
  refreshMatrix();
  if (agent?.id) openAgent(agent);
};

const loadAgents = async () => {
  try {
    await store.dispatch('captainAssistants/get');
  } catch {
    // The page shows what is already in the store; the next visit retries.
  } finally {
    hasLoaded.value = true;
  }
};

onMounted(() => {
  if (shouldShowPaywall(FEATURE_FLAGS.CAPTAIN)) {
    hasLoaded.value = true;
    return;
  }

  loadAgents();
  // The channel matrix API is admin-only; others get the summary from the
  // agent records.
  if (isAdmin.value) matrixStore.fetch();
});
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.NAV.GROUP')"
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
    :is-fetching="isFetching"
    :show-pagination-footer="false"
    :show-know-more="false"
  >
    <template #paywall>
      <CaptainPaywall />
    </template>

    <template #body>
      <div class="flex flex-col gap-4 pb-6">
        <div
          v-if="isAdmin && toggleableAgents.length"
          class="flex items-center justify-end"
        >
          <Button
            :label="
              hasActiveToggleableAgents
                ? t('CAPTAIN.GALLERY.DISABLE_ALL_AGENTS')
                : t('CAPTAIN.GALLERY.ENABLE_ALL_AGENTS')
            "
            color="slate"
            variant="faded"
            size="sm"
            :disabled="isBulkToggling"
            :is-loading="isBulkToggling"
            data-testid="agents-toggle-all"
            @click="handleToggleAllAgents"
          />
        </div>
        <p
          v-if="!agents.length"
          class="mb-0 text-body-main text-n-slate-11"
          data-testid="agents-empty"
        >
          {{ t('CAPTAIN.GALLERY.EMPTY') }}
        </p>
        <div
          v-if="agents.length || isAdmin"
          class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3"
        >
          <AgentGalleryCard
            v-for="agent in agents"
            :key="agent.id"
            :assistant="agent"
            :is-main="mainAgentId === Number(agent.id)"
            :stats="statsById[agent.id] || null"
            :can-toggle="isAdmin"
            :toggling="isToggling(agent.id) || isBulkToggling"
            @open="openAgent(agent)"
            @toggle-active="value => handleToggleActive(agent, value)"
            @make-main="makeMain(agent)"
          />
          <AgentNewTile v-if="isAdmin" @click="openCreateDialog" />
        </div>
      </div>
    </template>

    <CreateAgentDialog
      v-if="isAdmin"
      ref="createDialogRef"
      @created="handleCreated"
    />
  </PageLayout>
</template>
