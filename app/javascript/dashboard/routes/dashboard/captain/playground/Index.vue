<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useCaptainChannelMatrixStore } from 'dashboard/store/captain/channelMatrix';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import AssistantPlayground from 'dashboard/components-next/captain/assistant/AssistantPlayground.vue';

const { t } = useI18n();
const route = useRoute();
const store = useStore();
const { checkPermissions, shouldShowPaywall } = usePolicy();
const matrixStore = useCaptainChannelMatrixStore();
const configStore = useCaptainConfigStore();

const hasLoaded = ref(false);
const uiFlags = useMapGetter('captainAssistants/getUIFlags');
const assistants = useMapGetter('captainAssistants/getRecords');

const isAdmin = computed(() => checkPermissions(['administrator']));
const matrix = computed(() => matrixStore.getMatrix || null);
const mainAgentId = computed(() =>
  Number(matrix.value?.default_main_assistant_id || 0)
);

const activeAgents = computed(() =>
  (assistants.value || []).filter(agent => agent.active !== false)
);
const matrixAgents = computed(() =>
  (matrix.value?.assistants || []).filter(agent => agent.active !== false)
);

const entryAgentId = computed(() => {
  const pool = activeAgents.value.length
    ? activeAgents.value
    : matrixAgents.value;
  const configuredMain = pool.find(
    agent => Number(agent.id) === mainAgentId.value
  );
  if (configuredMain) return Number(configuredMain.id);
  const inboxMain = activeAgents.value.find(
    agent => agent.main_in_inbox_ids?.length
  );
  if (inboxMain) return Number(inboxMain.id);
  if (pool.length) return Number(pool[0].id);
  return Number(
    assistants.value?.[0]?.id || matrix.value?.assistants?.[0]?.id || 0
  );
});

const isFetching = computed(
  () =>
    !entryAgentId.value &&
    (Boolean(uiFlags.value?.fetchingList) || !hasLoaded.value)
);

const loadAgents = async () => {
  try {
    await store.dispatch('captainAssistants/get');
  } catch {
    // Keep existing store state if any.
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
  configStore.fetch({ clientMetadataOnly: true });
  if (isAdmin.value) matrixStore.fetch();
});
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.NAV.SANDBOX')"
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
    :is-fetching="isFetching"
    :show-pagination-footer="false"
    :show-know-more="false"
  >
    <template #paywall>
      <CaptainPaywall />
    </template>

    <template #body>
      <div
        v-if="entryAgentId"
        class="flex min-h-[32rem] w-full flex-col pb-4 lg:h-[calc(100vh-10rem)]"
        data-testid="captain-playground-page"
      >
        <AssistantPlayground
          :assistant-id="entryAgentId"
          :account-id="route.params.accountId"
          class="min-h-0 flex-1"
        />
      </div>
      <p
        v-else
        class="mb-0 text-body-main text-n-slate-11"
        data-testid="playground-empty"
      >
        {{ t('CAPTAIN.GALLERY.EMPTY') }}
      </p>
    </template>
  </PageLayout>
</template>
