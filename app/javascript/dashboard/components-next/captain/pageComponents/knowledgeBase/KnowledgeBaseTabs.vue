<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';

import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();

const KNOWLEDGE_BASE_ROUTES = {
  faqs: 'captain_assistants_responses_index',
  documents: 'captain_assistants_documents_index',
};

const tabs = computed(() => [
  {
    key: 'faqs',
    label: t('CAPTAIN.KNOWLEDGE_BASE.TABS.FAQS'),
    routeName: KNOWLEDGE_BASE_ROUTES.faqs,
  },
  {
    key: 'documents',
    label: t('CAPTAIN.KNOWLEDGE_BASE.TABS.DOCUMENTS'),
    routeName: KNOWLEDGE_BASE_ROUTES.documents,
  },
]);

const activeTabIndex = computed(() => {
  return route.name === KNOWLEDGE_BASE_ROUTES.documents ? 1 : 0;
});

const switchTab = tab => {
  if (!tab?.routeName || route.name === tab.routeName) return;

  router.push({
    name: tab.routeName,
    params: {
      accountId: route.params.accountId,
    },
  });
};
</script>

<template>
  <div class="flex flex-col gap-3 pb-4">
    <p class="max-w-3xl text-sm leading-5 text-n-slate-11">
      {{ t('CAPTAIN.KNOWLEDGE_BASE.DESCRIPTION') }}
    </p>
    <TabBar
      active-text-class="text-n-slate-12 scale-100"
      :tabs="tabs"
      :initial-active-tab="activeTabIndex"
      @tab-changed="switchTab"
    />
  </div>
</template>
