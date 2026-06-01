<script setup>
import { watch } from 'vue';
import { useRoute } from 'vue-router';
import { useUISettings } from 'dashboard/composables/useUISettings';

const route = useRoute();
const { uiSettings, updateUISettings } = useUISettings();

const openCaptainCopilotPanelByDefault = () => {
  if (uiSettings.value?.is_copilot_panel_open) return;

  updateUISettings({
    is_contact_sidebar_open: false,
    is_copilot_panel_open: true,
    is_crm_deal_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

watch(
  () => route.params.assistantId,
  newAssistantId => {
    if (
      newAssistantId &&
      newAssistantId !== String(uiSettings.value.last_active_assistant_id)
    ) {
      updateUISettings({
        last_active_assistant_id: Number(newAssistantId),
      });
    }
  },
  { immediate: true }
);

watch(
  () => [route.name, route.params.assistantId, route.params.navigationPath],
  () => {
    openCaptainCopilotPanelByDefault();
  },
  { immediate: true }
);
</script>

<template>
  <div class="flex w-full h-full min-h-0">
    <section class="flex flex-1 h-full px-0 overflow-hidden bg-n-surface-1">
      <router-view />
    </section>
  </div>
</template>
