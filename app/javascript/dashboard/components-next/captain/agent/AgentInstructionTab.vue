<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import {
  AGENT_TOOL_SCOPE,
  resolveAgentToolAccess,
} from 'dashboard/components-next/captain/pageComponents/assistant/toolAccessDefaults';
import AgentToolChips from './AgentToolChips.vue';
import AgentModelBlock from './AgentModelBlock.vue';
import AgentChannelsBlock from './AgentChannelsBlock.vue';
import AgentFollowUpsSummary from './AgentFollowUpsSummary.vue';

// «Инструкция» tab: the instruction editor with the @ tools / $ fields
// pickers and the read-only tool chips; side column with the «Модель»,
// «Каналы» and «Дожимы» blocks. The page owns the draft and the save.
const props = defineProps({
  assistant: { type: Object, required: true },
  draft: { type: Object, required: true },
  errors: { type: Object, default: () => ({}) },
  showErrors: { type: Boolean, default: false },
  canEdit: { type: Boolean, default: false },
  instructionMaxLength: { type: Number, default: 20000 },
});

const emit = defineEmits(['update:draft', 'openFollowUps']);

const { t } = useI18n();
const editorRef = ref(null);

const updateDraft = patch => emit('update:draft', { ...props.draft, ...patch });

const instruction = computed({
  get: () => props.draft.instruction || '',
  set: value => updateDraft({ instruction: value || '' }),
});
const model = computed({
  get: () => props.draft.model || '',
  set: value => updateDraft({ model: value || '' }),
});
const temperature = computed({
  get: () => props.draft.temperature ?? null,
  set: value => updateDraft({ temperature: value ?? null }),
});
const thinkingEffort = computed({
  get: () => props.draft.thinkingEffort || '',
  set: value => updateDraft({ thinkingEffort: value || '' }),
});

const toolAccess = computed(() =>
  resolveAgentToolAccess(props.assistant?.config?.tool_access || {})
);

const referenceActions = computed(() => [
  {
    id: 'tools',
    marker: '@',
    label: t('CAPTAIN.AGENT_PAGE.TOOLBAR.TOOLS'),
  },
  {
    id: 'fields',
    marker: '$',
    label: t('CAPTAIN.AGENT_PAGE.TOOLBAR.FIELDS'),
  },
]);

const openReferenceMenu = menuType => {
  editorRef.value?.openCaptainReferenceMenu?.(menuType);
};

const instructionError = computed(() => {
  if (!props.showErrors) return '';
  if (props.errors?.instruction === 'required') {
    return t('CAPTAIN.AGENT_PAGE.INSTRUCTION_REQUIRED');
  }
  if (props.errors?.instruction === 'max') {
    return t('CAPTAIN.AGENT_PAGE.INSTRUCTION_MAX', {
      max: props.instructionMaxLength,
    });
  }
  return '';
});
</script>

<template>
  <div
    class="grid gap-6 lg:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)]"
    data-test="agent-instruction-tab"
  >
    <div class="flex min-w-0 flex-col gap-4">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h2 class="mb-0 text-heading-2 text-n-slate-12">
          {{ t('CAPTAIN.AGENT_PAGE.INSTRUCTION_LABEL') }}
        </h2>
        <div v-if="canEdit" class="flex flex-wrap items-center gap-2">
          <Button
            v-for="action in referenceActions"
            :key="action.id"
            size="sm"
            color="slate"
            variant="faded"
            class="!px-3"
            :data-test="`agent-reference-${action.id}`"
            @mousedown.prevent
            @click="openReferenceMenu(action.id)"
          >
            <span class="flex min-w-0 gap-1 truncate">
              <span class="font-semibold text-n-brand">
                {{ action.marker }}
              </span>
              <span class="min-w-0 truncate">{{ action.label }}</span>
            </span>
          </Button>
        </div>
      </div>
      <div
        v-if="!canEdit"
        class="max-h-[40rem] overflow-y-auto whitespace-pre-wrap break-words rounded-lg bg-n-alpha-black2 px-3 py-3 text-body-para text-n-slate-12 outline outline-1 -outline-offset-1 outline-n-weak"
        data-test="agent-instruction-readonly"
      >
        {{ instruction }}
      </div>
      <Editor
        v-else
        ref="editorRef"
        v-model="instruction"
        override-line-breaks
        auto-height
        :editor-key="`captain:agent:${assistant.id}:instruction`"
        :placeholder="t('CAPTAIN.AGENT_PAGE.INSTRUCTION_PLACEHOLDER')"
        :max-length="instructionMaxLength"
        :initial-height="560"
        min-height="28rem"
        :message="instructionError"
        :message-type="instructionError ? 'error' : 'info'"
        class="z-0"
        enable-captain-tools
        enable-captain-fields
        :captain-context-assistant-id="assistant.id"
        :captain-tool-access="toolAccess"
        :captain-tool-scope="AGENT_TOOL_SCOPE"
      />
      <AgentToolChips :assistant="assistant" :instruction="instruction" />
    </div>

    <aside class="flex min-w-0 flex-col gap-6">
      <AgentModelBlock
        v-model:model="model"
        v-model:temperature="temperature"
        v-model:effort="thinkingEffort"
        :assistant="assistant"
        :disabled="!canEdit"
      />
      <AgentChannelsBlock :assistant="assistant" :can-configure="canEdit" />
      <AgentFollowUpsSummary
        :assistant="assistant"
        @open="emit('openFollowUps')"
      />
    </aside>
  </div>
</template>
