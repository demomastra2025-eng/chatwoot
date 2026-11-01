<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { usePromptInspectorAccess } from 'dashboard/composables/captain/usePromptInspectorAccess';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

import Button from 'dashboard/components-next/button/Button.vue';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import AgentGalleryCard from 'dashboard/components-next/captain/agent/AgentGalleryCard.vue';
import AgentNewTile from 'dashboard/components-next/captain/agent/AgentNewTile.vue';
import AgentSwitchOffDialog from 'dashboard/components-next/captain/agent/AgentSwitchOffDialog.vue';
import CreateAgentDialog from 'dashboard/components-next/captain/agent/CreateAgentDialog.vue';
import { useAgentActiveToggle } from 'dashboard/components-next/captain/agent/useAgentActiveToggle';
import {
  enabledAgentsCount,
  isAgentActive,
  switchOffWarnings,
} from 'dashboard/components-next/captain/agent/agentSwitchOff';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();
const { checkPermissions, shouldShowPaywall } = usePolicy();
const { setActive, isToggling } = useAgentActiveToggle();

const createDialogRef = ref(null);
const switchOffDialogRef = ref(null);
const hasLoaded = ref(false);
const isBulkToggling = ref(false);
// What the switch-off confirmation will do when it is confirmed.
const pendingSwitchOff = ref(null);
const switchOffText = ref('');

const uiFlags = useMapGetter('captainAssistants/getUIFlags');
// getRecords already hides the internal assistants: only AI agents are listed.
const assistants = useMapGetter('captainAssistants/getRecords');
const inboxes = useMapGetter('inboxes/getInboxes');

const isAdmin = computed(() => checkPermissions(['administrator']));
const { canInspectPrompts } = usePromptInspectorAccess();
const canCreate = computed(() => isAdmin.value && canInspectPrompts.value);

const agents = computed(() =>
  [...(assistants.value || [])].sort((first, second) => {
    const firstActive = isAgentActive(first);
    const secondActive = isAgentActive(second);
    if (firstActive !== secondActive) return firstActive ? -1 : 1;

    return String(first.name || '').localeCompare(
      String(second.name || ''),
      undefined,
      { sensitivity: 'base' }
    );
  })
);

const enabledCount = computed(() => enabledAgentsCount(agents.value));
const hasActiveAgents = computed(() => enabledCount.value > 0);

const isFetching = computed(
  () =>
    !agents.value.length &&
    (Boolean(uiFlags.value?.fetchingList) || !hasLoaded.value)
);

const openAgent = agent => {
  router.push({
    name: 'captain_agent_show',
    params: { accountId: route.params.accountId, assistantId: agent.id },
  });
};

const openSandbox = () => {
  router.push({
    name: 'captain_playground_index',
    params: { accountId: route.params.accountId },
  });
};

const askSwitchOff = (text, action) => {
  switchOffText.value = text;
  pendingSwitchOff.value = action;
  switchOffDialogRef.value?.open();
};

const confirmSwitchOff = async () => {
  const action = pendingSwitchOff.value;
  pendingSwitchOff.value = null;
  if (action) await action();
};

// Every agent has the same switch. Switching one off asks first when it
// answers the calls of a number, or when it is the last one that is on.
const handleToggleActive = async (agent, active) => {
  if (active) {
    await setActive(agent, true);
    return;
  }

  const warnings = switchOffWarnings({
    agent,
    agents: agents.value,
    inboxes: inboxes.value || [],
  }).map(warning => t(warning.key, warning.params));
  if (!warnings.length) {
    await setActive(agent, false);
    return;
  }

  askSwitchOff(warnings.join(' '), () => setActive(agent, false));
};

const toggleAllAgents = async nextActive => {
  const targets = agents.value.filter(
    agent => isAgentActive(agent) !== nextActive
  );
  if (!targets.length) return;

  isBulkToggling.value = true;
  try {
    await Promise.all(targets.map(agent => setActive(agent, nextActive)));
  } finally {
    isBulkToggling.value = false;
  }
};

const handleToggleAllAgents = async () => {
  if (!isAdmin.value || isBulkToggling.value || !agents.value.length) return;
  if (hasActiveAgents.value) {
    askSwitchOff(t('CAPTAIN.GALLERY.CONFIRM_DISABLE_ALL'), () =>
      toggleAllAgents(false)
    );
    return;
  }
  await toggleAllAgents(true);
};

const openCreateDialog = () => {
  if (canCreate.value) createDialogRef.value?.dialogRef?.open();
};

const handleCreated = agent => {
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
          v-if="agents.length"
          class="flex flex-wrap items-center justify-end gap-2"
        >
          <Button
            :label="t('CAPTAIN.NAV.SANDBOX')"
            icon="i-lucide-message-circle"
            color="slate"
            variant="faded"
            size="sm"
            data-testid="agents-open-sandbox"
            @click="openSandbox"
          />
          <Button
            v-if="isAdmin"
            :label="
              hasActiveAgents
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
          v-if="agents.length || canCreate"
          class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3"
        >
          <AgentGalleryCard
            v-for="agent in agents"
            :key="agent.id"
            :assistant="agent"
            :enabled-count="enabledCount"
            :can-toggle="isAdmin"
            :toggling="isToggling(agent.id) || isBulkToggling"
            @open="openAgent(agent)"
            @toggle-active="value => handleToggleActive(agent, value)"
          />
          <AgentNewTile v-if="canCreate" @click="openCreateDialog" />
        </div>
      </div>
    </template>

    <CreateAgentDialog
      v-if="canCreate"
      ref="createDialogRef"
      @created="handleCreated"
    />
    <AgentSwitchOffDialog
      v-if="isAdmin"
      ref="switchOffDialogRef"
      :description="switchOffText"
      @confirm="confirmSwitchOff"
    />
  </PageLayout>
</template>
