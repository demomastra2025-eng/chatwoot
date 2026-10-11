<script setup>
import { computed, reactive, watch, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import AgentSelector from 'dashboard/components-next/captain/assistant/AgentSelector.vue';
import {
  activeExternalAssistants,
  normalizeAssistantIds,
} from 'dashboard/components-next/captain/assistant/assistantAccess';

const props = defineProps({
  assistant: { type: Object, default: () => ({}) },
});
const { t } = useI18n();
const store = useStore();
const assistants = useMapGetter('captainAssistants/getRecords');
const uiFlags = useMapGetter('captainAssistants/getUIFlags');
const state = reactive({
  active: true,
  routingDescription: '',
  handoffIds: [],
});
const targets = computed(() =>
  activeExternalAssistants(assistants.value, props.assistant.id)
);
watch(
  () => props.assistant,
  assistant => {
    state.active = assistant.active !== false;
    state.routingDescription = assistant.routing_description || '';
    state.handoffIds = normalizeAssistantIds(assistant.handoff_agent_ids || []);
  },
  { immediate: true }
);
onMounted(() => {
  if (!uiFlags.value.fetchingList) store.dispatch('captainAssistants/get');
});
const buildPayload = () => {
  if (uiFlags.value.fetchingList) return null;
  const allowedIds = new Set(
    targets.value.map(assistant => Number(assistant.id))
  );
  return {
    assistant: {
      active: state.active,
      routing_description: state.routingDescription.trim(),
      handoff_agent_ids: state.handoffIds.filter(id => allowedIds.has(id)),
    },
  };
};
defineExpose({ buildPayload });
</script>

<template>
  <section class="flex flex-col gap-4" data-test="agent-routing-settings">
    <label class="flex items-center justify-between gap-3">
      <span class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.ROUTING.ACTIVE') }}
        <span class="mt-1 block text-xs font-normal text-n-slate-11">
          {{ t('CAPTAIN.ASSISTANTS.ROUTING.ACTIVE_HELP') }}
        </span>
      </span>
      <Switch v-model="state.active" />
    </label>
    <Input
      v-model="state.routingDescription"
      :label="t('CAPTAIN.ASSISTANTS.ROUTING.DESCRIPTION')"
      :placeholder="t('CAPTAIN.ASSISTANTS.ROUTING.DESCRIPTION_PLACEHOLDER')"
      :max-length="1000"
    />
    <AgentSelector
      v-model="state.handoffIds"
      :assistants="targets"
      :disabled="uiFlags.fetchingList"
      :label="t('CAPTAIN.ASSISTANTS.ROUTING.TARGETS')"
    />
    <p class="m-0 text-xs text-n-slate-11">
      {{ t('CAPTAIN.ASSISTANTS.ROUTING.TARGETS_HELP') }}
    </p>
  </section>
</template>
