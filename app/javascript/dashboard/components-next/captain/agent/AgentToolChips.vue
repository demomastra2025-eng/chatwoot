<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import CaptainToolsAPI from 'dashboard/api/captain/tools';
import {
  extractCaptainToolReferenceIds,
  localizeCatalogTool,
} from 'dashboard/helper/captainCatalog';
import { AGENT_TOOL_SCOPE } from 'dashboard/components-next/captain/pageComponents/assistant/toolAccessDefaults';

// Read-only row under the instruction: what the agent can call right now.
// That is every tool mentioned in the instruction plus the hidden
// non-capability tools still selected in config.tool_access.agent (they work
// without a mention). Capabilities (FAQ, handoff, notes, web) are global
// settings and are not listed. The tool catalog is admin-only: on any error
// the row is hidden.
const props = defineProps({
  assistant: { type: Object, required: true },
  instruction: { type: String, default: '' },
});

// Same list as the @-picker (TagTools), which never offers these tools.
const CAPABILITY_TOOL_IDS = new Set([
  'faq_lookup',
  'handoff',
  'resolve_conversation',
  'web_search',
  'web_scrape_url',
  'add_contact_note',
  'add_private_note',
  'cancel_response',
  'send_notification',
]);

const { t, te } = useI18n();

const catalog = ref([]);
const isLoaded = ref(false);
const hasError = ref(false);
let requestSequence = 0;

const loadCatalog = async assistantId => {
  requestSequence += 1;
  const sequence = requestSequence;
  isLoaded.value = false;
  hasError.value = false;
  if (!assistantId) return;

  try {
    const response = await CaptainToolsAPI.get({
      assistantId,
      scope: AGENT_TOOL_SCOPE,
    });
    if (sequence !== requestSequence) return;
    catalog.value = Array.isArray(response?.data) ? response.data : [];
    isLoaded.value = true;
  } catch {
    if (sequence !== requestSequence) return;
    catalog.value = [];
    hasError.value = true;
  }
};

watch(
  () => props.assistant?.id,
  assistantId => loadCatalog(assistantId),
  { immediate: true }
);

const catalogById = computed(
  () => new Map(catalog.value.map(tool => [String(tool.id), tool]))
);

const isCapabilityTool = id =>
  CAPABILITY_TOOL_IDS.has(id) ||
  catalogById.value.get(id)?.capability_tool === true;

const mentionedIds = computed(() =>
  extractCaptainToolReferenceIds(props.instruction).map(String)
);

const hiddenAccessIds = computed(() => {
  const agentAccess = props.assistant?.config?.tool_access?.[AGENT_TOOL_SCOPE];
  if (!agentAccess || agentAccess.enabled === false) return [];
  const ids = Array.isArray(agentAccess.tool_ids) ? agentAccess.tool_ids : [];
  return ids.map(String).filter(id => !isCapabilityTool(id));
});

const toolTitle = id => {
  const tool = catalogById.value.get(id);
  if (!tool) return id;
  return localizeCatalogTool(tool, { t, te })?.title || tool.title || id;
};

const chips = computed(() => {
  const mentioned = new Set(mentionedIds.value);
  const ids = Array.from(new Set([...mentioned, ...hiddenAccessIds.value]));
  return ids.map(id => ({
    id,
    title: toolTitle(id),
    notMentioned: !mentioned.has(id),
  }));
});

const isVisible = computed(
  () => isLoaded.value && !hasError.value && chips.value.length > 0
);
</script>

<template>
  <div
    v-if="isVisible"
    class="flex flex-wrap items-center gap-2"
    data-test="agent-tool-chips"
  >
    <span class="text-body-main text-n-slate-11">
      {{ t('CAPTAIN.AGENT_PAGE.TOOLS_ROW') }}
    </span>
    <span
      v-for="chip in chips"
      :key="chip.id"
      class="inline-flex min-w-0 max-w-full items-center gap-1 rounded-lg bg-n-alpha-2 px-2 py-0.5 text-label-small text-n-slate-12"
      :title="chip.id"
      data-test="agent-tool-chip"
    >
      <span class="min-w-0 truncate">{{ chip.title }}</span>
      <span
        v-if="chip.notMentioned"
        class="shrink-0 text-n-slate-10"
        data-test="agent-tool-chip-not-mentioned"
      >
        {{ t('CAPTAIN.AGENT_PAGE.TOOL_NOT_MENTIONED') }}
      </span>
    </span>
  </div>
</template>
