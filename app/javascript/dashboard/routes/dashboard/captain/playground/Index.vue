<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { usePromptInspectorAccess } from 'dashboard/composables/captain/usePromptInspectorAccess';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import AssistantPlayground from 'dashboard/components-next/captain/assistant/AssistantPlayground.vue';

const { t } = useI18n();
const route = useRoute();
const store = useStore();
const { shouldShowPaywall } = usePolicy();
const configStore = useCaptainConfigStore();
const { canInspectPrompts } = usePromptInspectorAccess();

const hasLoaded = ref(false);
const uiFlags = useMapGetter('captainAssistants/getUIFlags');
const assistants = useMapGetter('captainAssistants/getRecords');

// The sandbox tries out the whole AI of the workspace: there is no start agent.
// It needs at least one agent to exist; the AI picks among the enabled ones.
const hasAgents = computed(() => (assistants.value || []).length > 0);

const isFetching = computed(
  () =>
    !hasAgents.value &&
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
  if (canInspectPrompts.value) configStore.fetch({ clientMetadataOnly: true });
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
        v-if="hasAgents"
        class="flex min-h-[32rem] w-full flex-col pb-4 lg:h-[calc(100vh-10rem)]"
        data-testid="captain-playground-page"
      >
        <AssistantPlayground
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
