<script setup>
import { onMounted, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useUISettings } from 'dashboard/composables/useUISettings';

const CAPTAIN_COPILOT_CLOSED_SESSION_KEY = 'captain_copilot_panel_closed';

const route = useRoute();
const { uiSettings, updateUISettings } = useUISettings();

const openCaptainCopilotPanelByDefault = () => {
  if (window.sessionStorage.getItem(CAPTAIN_COPILOT_CLOSED_SESSION_KEY)) return;
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

onMounted(() => {
  openCaptainCopilotPanelByDefault();
});
</script>

<template>
  <div class="flex w-full h-full min-h-0">
    <section class="flex flex-1 h-full px-0 overflow-hidden bg-n-surface-1">
      <router-view />
    </section>
  </div>
</template>
