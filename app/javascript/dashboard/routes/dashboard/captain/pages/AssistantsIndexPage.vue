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

const routeToLastActiveAssistant = () => {
  const params = generateRouterParams();

  // No assistants found, redirect to create page
  if (!params) {
    return routeToView('captain_assistants_create_index', {
      accountId: route.params.accountId,
    });
  }

  const { navigationPath } = route.params;
  const isAValidRoute = [
    'captain_assistants_responses_index', // Faq page
    'captain_assistants_documents_index', // Document page
    'captain_assistants_scenarios_index', // Scenario page
    'captain_assistants_playground_index', // Playground page
    'captain_assistants_channels_index', // Channels page
    'captain_tools_index', // Tools page
    'captain_assistants_settings_index', // Settings page
    'captain_assistants_prompts_index', // Prompts page
    'captain_assistants_restrictions_index', // Restrictions page
    'captain_assistants_access_index', // Access page
  ].includes(navigationPath);

  let navigateTo = 'captain_assistants_responses_index';

  if (isAValidRoute) {
    navigateTo =
      navigationPath === 'captain_assistants_access_index'
        ? 'captain_assistants_settings_index'
        : navigationPath;
  }

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
