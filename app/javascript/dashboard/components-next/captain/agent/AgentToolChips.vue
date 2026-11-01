<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import CaptainToolsAPI from 'dashboard/api/captain/tools';
import {
  extractCaptainToolReferenceIds,
  localizeCatalogTool,
} from 'dashboard/helper/captainCatalog';
import { AGENT_TOOL_SCOPE } from 'dashboard/components-next/captain/pageComponents/assistant/toolAccessDefaults';

// Canonical bindings are the only grant source after cutover. Legacy records
// keep their display until the platform performs an explicit migration.
const props = defineProps({
  assistant: { type: Object, required: true },
  instruction: { type: String, default: '' },
  capabilities: { type: Object, default: null },
  canEdit: { type: Boolean, default: false },
});

const emit = defineEmits(['update:capabilities']);
const canonical = computed(
  () => props.capabilities || props.assistant?.config?.capabilities
);
const isCanonical = computed(() => canonical.value?.version === 1);
const canonicalScope = computed(
  () => canonical.value?.scopes?.[AGENT_TOOL_SCOPE]
);
const updateScope = patch => {
  if (!props.canEdit || !isCanonical.value) return;
  emit('update:capabilities', {
    ...canonical.value,
    scopes: {
      ...canonical.value.scopes,
      [AGENT_TOOL_SCOPE]: { ...canonicalScope.value, ...patch },
    },
  });
};
const scopeEnabled = computed({
  get: () => canonicalScope.value?.enabled === true,
  set: enabled => updateScope({ enabled }),
});
const selectedIds = computed({
  get: () => canonicalScope.value?.tool_ids || [],
  set: tool_ids => updateScope({ tool_ids }),
});

// Same list as the @-picker (TagTools), which never offers these tools.
const CAPABILITY_TOOL_IDS = new Set([
  'faq_lookup',
  'handoff',
  'resolve_conversation',
  'web_search',
  'web_scrape_url',
  'cancel_response',
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
  extractCaptainToolReferenceIds(props.instruction)
    .map(String)
    .filter(id => !isCapabilityTool(id))
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
  if (isCanonical.value) {
    if (canonicalScope.value?.enabled !== true) return [];
    const ids = Array.isArray(canonicalScope.value.tool_ids)
      ? canonicalScope.value.tool_ids
      : [];
    return [...new Set(ids.map(String))].map(id => ({
      id,
      title: toolTitle(id),
      notMentioned: false,
    }));
  }
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
  <section
    v-if="canEdit && isCanonical && isLoaded && !hasError"
    class="border-t border-n-weak pt-4"
    data-test="agent-bindings"
  >
    <label class="mb-0 flex items-center gap-2 text-body-main text-n-slate-12">
      <Switch
        v-model="scopeEnabled"
        :aria-label="t('CAPTAIN.AGENT_PAGE.TOOLS_ROW')"
      />
      {{ t('CAPTAIN.AGENT_PAGE.TOOLS_ROW') }}
    </label>
    <div class="mt-4 grid gap-3 sm:grid-cols-2">
      <label
        v-for="tool in catalog"
        :key="tool.id"
        :for="`agent-tool-${assistant.id}-${tool.id}`"
        class="mb-0 flex min-w-0 items-start gap-2 text-body-main font-normal text-n-slate-12"
      >
        <Checkbox
          :id="`agent-tool-${assistant.id}-${tool.id}`"
          v-model="selectedIds"
          :value="String(tool.id)"
          :disabled="!scopeEnabled"
        />
        <span class="min-w-0 break-words">{{
          toolTitle(String(tool.id))
        }}</span>
      </label>
    </div>
  </section>
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
