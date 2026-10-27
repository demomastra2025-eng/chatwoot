<script setup>
import { useI18n } from 'vue-i18n';
import Switch from 'dashboard/components-next/switch/Switch.vue';

// «Что агент ищет сам» block of the agent page side column: the FAQ lookup and
// the service search are on for every agent; each one can be switched off for
// this agent. The page owns the draft and the save.
const props = defineProps({
  draft: { type: Object, required: true },
  disabled: { type: Boolean, default: false },
});

const emit = defineEmits(['update:draft']);

const { t } = useI18n();

const setField = (field, value) =>
  emit('update:draft', { ...props.draft, [field]: Boolean(value) });
</script>

<template>
  <section
    class="flex flex-col outline outline-1 -outline-offset-1 outline-n-weak rounded-xl bg-n-solid-2 divide-y divide-n-weak"
    data-test="agent-read-tools"
  >
    <div class="px-5 py-4">
      <h3 class="mb-0 text-heading-2 text-n-slate-12">
        {{ t('CAPTAIN.AGENT_PAGE.READ_TOOLS.TITLE') }}
      </h3>
    </div>
    <label class="flex items-center justify-between gap-3 px-5 py-4">
      <span class="min-w-0">
        <span class="block text-body-main text-n-slate-12">
          {{ t('CAPTAIN.AGENT_PAGE.READ_TOOLS.FAQ') }}
        </span>
        <span class="block text-label-small text-n-slate-11">
          {{ t('CAPTAIN.AGENT_PAGE.READ_TOOLS.FAQ_HINT') }}
        </span>
      </span>
      <Switch
        :model-value="draft.faqLookup"
        :disabled="disabled"
        data-test="agent-read-tool-faq"
        @update:model-value="setField('faqLookup', $event)"
      />
    </label>
    <label class="flex items-center justify-between gap-3 px-5 py-4">
      <span class="min-w-0">
        <span class="block text-body-main text-n-slate-12">
          {{ t('CAPTAIN.AGENT_PAGE.READ_TOOLS.SERVICES') }}
        </span>
        <span class="block text-label-small text-n-slate-11">
          {{ t('CAPTAIN.AGENT_PAGE.READ_TOOLS.SERVICES_HINT') }}
        </span>
      </span>
      <Switch
        :model-value="draft.serviceSearch"
        :disabled="disabled"
        data-test="agent-read-tool-services"
        @update:model-value="setField('serviceSearch', $event)"
      />
    </label>
  </section>
</template>
