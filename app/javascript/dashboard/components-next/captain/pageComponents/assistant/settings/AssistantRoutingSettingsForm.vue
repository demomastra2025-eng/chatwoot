<script setup>
import { reactive, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

// Whether the agent works at all, and the sentence the other agents of a
// channel use to decide when to give a request to this one. Which agents work
// in a channel (and which one is the main agent) is set on the «Каналы» grid,
// not here.
const props = defineProps({
  assistant: { type: Object, default: () => ({}) },
});
const { t } = useI18n();
const state = reactive({
  active: true,
  routingDescription: '',
});
watch(
  () => props.assistant,
  assistant => {
    state.active = assistant.active !== false;
    state.routingDescription = assistant.routing_description || '';
  },
  { immediate: true }
);
const buildPayload = () => ({
  assistant: {
    active: state.active,
    routing_description: state.routingDescription.trim(),
  },
});
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
  </section>
</template>
