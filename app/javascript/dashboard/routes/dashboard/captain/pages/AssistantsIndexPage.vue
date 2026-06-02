<script setup>
import { computed, nextTick, onMounted } from 'vue';
import { useStore } from 'vuex';
import { useRoute, useRouter } from 'vue-router';
import { useUISettings } from 'dashboard/composables/useUISettings';

import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const store = useStore();
const router = useRouter();
const { uiSettings } = useUISettings();
const route = useRoute();

const assistants = computed(
  () => store.getters['captainAssistants/getRecords']
);

const isAssistantPresent = assistantId => {
  return !!assistants.value.find(a => a.id === Number(assistantId));
};

const routeToView = (name, params) => {
  router.replace({ name, params, replace: true });
};

const generateRouterParams = () => {
  const { last_active_assistant_id: lastActiveAssistantId } =
    uiSettings.value || {};

  if (isAssistantPresent(lastActiveAssistantId)) {
    return {
      assistantId: lastActiveAssistantId,
    };
  }

  if (assistants.value.length > 0) {
    const { id: assistantId } = assistants.value[0];
    return { assistantId };
  }

  return null;
};

const LEGACY_NAVIGATION_ALIASES = {
  captain_assistants_playground_index: 'captain_assistants_prompts_index',
  captain_assistants_responses_index: 'knowledge_base',
  captain_assistants_documents_index: 'documents',
  captain_tools_index: 'tools',
};

const SHARED_NAVIGATION_ROUTES = {
  knowledge_base: 'captain_assistants_responses_index',
  documents: 'captain_assistants_documents_index',
  tools: 'captain_tools_index',
};

const VALID_NAVIGATION_ROUTES = [
  'captain_assistants_scenarios_index', // Legacy prompts alias
  'captain_assistants_channels_index', // Channels page
  'captain_assistants_settings_index', // Settings page
  'captain_assistants_prompts_index', // Prompts page
  'captain_assistants_restrictions_index', // Legacy prompts alias
  'captain_assistants_guardrails_index', // Legacy prompts alias
  'captain_assistants_guidelines_index', // Legacy prompts alias
];

const routeToLastActiveAssistant = () => {
  const params = generateRouterParams();

  // No assistants found, redirect to create page
  if (!params) {
    return routeToView('captain_assistants_create_index', {
      accountId: route.params.accountId,
    });
  }

  const { navigationPath } = route.params;
  const aliasedNavigationPath =
    LEGACY_NAVIGATION_ALIASES[navigationPath] || navigationPath;

  if (SHARED_NAVIGATION_ROUTES[aliasedNavigationPath]) {
    return routeToView(SHARED_NAVIGATION_ROUTES[aliasedNavigationPath], {
      accountId: route.params.accountId,
    });
  }

  const navigateTo = VALID_NAVIGATION_ROUTES.includes(aliasedNavigationPath)
    ? aliasedNavigationPath
    : 'captain_assistants_prompts_index';

  return routeToView(navigateTo, {
    accountId: route.params.accountId,
    ...params,
  });
};

const performRouting = async () => {
  await store.dispatch('captainAssistants/get');
  nextTick(() => routeToLastActiveAssistant());
};

onMounted(() => performRouting());
</script>

<template>
  <div
    class="flex items-center justify-center w-full bg-n-surface-1 text-n-slate-11"
  >
    <Spinner />
  </div>
</template>
