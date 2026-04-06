<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import { useMapGetter } from 'dashboard/composables/store';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import ContextAccessSettings from 'dashboard/components-next/captain/pageComponents/assistant/ContextAccessSettings.vue';
import ToolAccessSettings from 'dashboard/components-next/captain/pageComponents/assistant/ToolAccessSettings.vue';

const { t } = useI18n();
const route = useRoute();
const store = useStore();

const basicContextAccess = ref({});
const basicToolAccess = ref({});

const uiFlags = useMapGetter('captainAssistants/getUIFlags');
const isFetching = computed(() => uiFlags.value.fetchingItem);
const assistantId = computed(() => Number(route.params.assistantId));
const assistant = computed(() =>
  store.getters['captainAssistants/getRecord'](assistantId.value)
);
const isInternalAssistant = computed(
  () => assistant.value?.usage_mode === 'internal_assistant'
);
const isExternalAgent = computed(() => !isInternalAssistant.value);

onMounted(() => {
  store.dispatch('captainAssistants/show', assistantId.value);
});

watch(
  assistant,
  currentAssistant => {
    basicContextAccess.value = currentAssistant?.config?.context_access || {};
    basicToolAccess.value = currentAssistant?.config?.tool_access || {};
  },
  { immediate: true }
);

const handleAccessSave = async () => {
  try {
    await store.dispatch('captainAssistants/update', {
      id: assistantId.value,
      assistant: {
        config: {
          ...(assistant.value?.config || {}),
          context_access: basicContextAccess.value,
          tool_access: basicToolAccess.value,
        },
      },
    });
    useAlert(t('CAPTAIN.ASSISTANTS.EDIT.SUCCESS_MESSAGE'));
  } catch (error) {
    const errorMessage =
      error?.message || t('CAPTAIN.ASSISTANTS.EDIT.ERROR_MESSAGE');
    useAlert(errorMessage);
  }
};
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.ACCESS.LABEL')"
    :is-fetching="isFetching"
    :show-pagination-footer="false"
    :show-know-more="false"
    :button-label="t('CAPTAIN.ASSISTANTS.FORM.SAVE')"
    button-icon=""
    @click="handleAccessSave"
  >
    <template #body>
      <div class="flex flex-col gap-6">
        <div class="grid gap-6 xl:grid-cols-2 xl:items-start">
          <div class="rounded-2xl bg-n-solid-1 p-5 md:p-6">
            <ContextAccessSettings
              v-model="basicContextAccess"
              :assistant-id="assistant?.id"
            />
          </div>
          <div class="rounded-2xl bg-n-solid-1 p-5 md:p-6">
            <ToolAccessSettings
              v-model="basicToolAccess"
              :assistant-id="assistant?.id"
              :allowed-scopes="isExternalAgent ? ['agent'] : ['assistant']"
            />
          </div>
        </div>
      </div>
    </template>
  </PageLayout>
</template>
