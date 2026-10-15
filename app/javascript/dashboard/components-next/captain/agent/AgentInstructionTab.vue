<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import {
  AGENT_TOOL_SCOPE,
  resolveAgentToolAccess,
} from 'dashboard/components-next/captain/pageComponents/assistant/toolAccessDefaults';
import AgentToolChips from './AgentToolChips.vue';
import AgentModelBlock from './AgentModelBlock.vue';
import AgentFollowUpsSummary from './AgentFollowUpsSummary.vue';
import Select from 'dashboard/components-next/select/Select.vue';

// «Инструкция» tab: the instruction editor with the @ tools / $ fields
// pickers and the read-only tool chips; side column with the routing/booking,
// «Модель», and «Дожимы» blocks. The page owns the draft and the save.
const props = defineProps({
  assistant: { type: Object, required: true },
  draft: { type: Object, required: true },
  errors: { type: Object, default: () => ({}) },
  showErrors: { type: Boolean, default: false },
  canEdit: { type: Boolean, default: false },
  instructionMaxLength: { type: Number, default: 20000 },
  teams: { type: Array, default: () => [] },
  bookingResources: { type: Array, default: () => [] },
});

const emit = defineEmits(['update:draft', 'openFollowUps']);

const { t } = useI18n();
const editorRef = ref(null);
const bookingDropdownOpen = ref(false);

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
const teamOptions = computed(() => [
  { value: '', label: t('CAPTAIN.AGENT_PAGE.NO_HANDOFF_TEAM') },
  ...props.teams.map(team => ({ value: String(team.id), label: team.name })),
]);

const selectedResourceIds = computed(() =>
  (props.draft.bookingResourceIds || []).map(Number).filter(Boolean)
);

const selectedResourceSet = computed(() => new Set(selectedResourceIds.value));

const selectedResourceItems = computed(() =>
  props.bookingResources.filter(resource =>
    selectedResourceSet.value.has(Number(resource.id))
  )
);

const bookingTriggerLabel = computed(() => {
  const count = selectedResourceIds.value.length;
  if (!count) return t('CAPTAIN.AGENT_PAGE.BOOKING_SCOPE_ALL');
  if (count === 1 && selectedResourceItems.value.length === 1) {
    return selectedResourceItems.value[0].name;
  }
  return t('CAPTAIN.AGENT_PAGE.BOOKING_SCOPE_SELECTED', { count });
});

const isResourceSelected = resourceId =>
  selectedResourceSet.value.has(Number(resourceId));

const toggleBookingResource = resourceId => {
  if (!props.canEdit) return;
  const numericId = Number(resourceId);
  if (!numericId) return;
  const current = [...selectedResourceIds.value];
  const index = current.indexOf(numericId);
  if (index >= 0) {
    current.splice(index, 1);
  } else {
    current.push(numericId);
  }
  updateDraft({ bookingResourceIds: current });
};

const clearBookingResources = () => {
  if (!props.canEdit) return;
  updateDraft({ bookingResourceIds: [] });
  bookingDropdownOpen.value = false;
};

const toggleBookingDropdown = () => {
  if (!props.canEdit) return;
  bookingDropdownOpen.value = !bookingDropdownOpen.value;
};

const closeBookingDropdown = () => {
  bookingDropdownOpen.value = false;
};

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
      <section
        class="flex flex-col divide-y divide-n-weak rounded-xl bg-n-solid-2 outline outline-1 -outline-offset-1 outline-n-weak"
        data-test="agent-routing-block"
      >
        <div class="flex flex-col gap-4 px-5 py-4">
          <div class="flex flex-col gap-1.5">
            <label
              for="agent-handoff-team"
              class="mb-0 text-heading-3 text-n-slate-12"
            >
              {{ t('CAPTAIN.AGENT_PAGE.HANDOFF_TEAM') }}
            </label>
            <Select
              id="agent-handoff-team"
              :model-value="String(draft.handoffTeamId || '')"
              :options="teamOptions"
              :disabled="!canEdit"
              class="w-full"
              @update:model-value="updateDraft({ handoffTeamId: $event })"
            />
          </div>

          <div
            v-on-clickaway="closeBookingDropdown"
            class="relative flex flex-col gap-1.5"
            data-test="agent-booking-scope"
          >
            <label class="mb-0 text-heading-3 text-n-slate-12">
              {{ t('CAPTAIN.AGENT_PAGE.BOOKING_SCOPE') }}
            </label>

            <button
              type="button"
              :disabled="!canEdit"
              class="flex w-full items-center justify-between gap-2 rounded-lg bg-n-surface-1 px-3 py-2 text-left text-sm text-n-slate-12 outline outline-1 -outline-offset-1 outline-n-weak transition-all duration-200 hover:outline-n-slate-6 focus:outline-n-brand disabled:cursor-not-allowed disabled:bg-n-slate-2 disabled:opacity-60"
              data-test="booking-scope-trigger"
              @click="toggleBookingDropdown"
            >
              <span class="min-w-0 truncate">{{ bookingTriggerLabel }}</span>
              <Icon
                icon="i-lucide-chevron-down"
                class="size-4 shrink-0 text-n-slate-11 transition-transform duration-150"
                :class="{ 'rotate-180': bookingDropdownOpen }"
              />
            </button>

            <div
              v-if="selectedResourceItems.length"
              class="flex flex-wrap gap-1.5 pt-0.5"
              data-test="booking-scope-chips"
            >
              <span
                v-for="resource in selectedResourceItems"
                :key="resource.id"
                class="inline-flex items-center gap-1 rounded-lg bg-n-alpha-2 px-2.5 py-1 text-xs font-medium text-n-slate-12"
              >
                <span class="max-w-48 truncate">{{ resource.name }}</span>
                <button
                  v-if="canEdit"
                  type="button"
                  class="inline-flex items-center justify-center rounded text-n-slate-10 hover:text-n-slate-12"
                  :aria-label="resource.name"
                  @click.stop="toggleBookingResource(resource.id)"
                >
                  <Icon icon="i-lucide-x" class="size-3" />
                </button>
              </span>
            </div>

            <div
              v-if="bookingDropdownOpen"
              class="absolute top-full left-0 right-0 z-30 mt-1 flex max-h-60 flex-col overflow-y-auto rounded-xl bg-n-solid-2 p-1.5 shadow-lg outline outline-1 -outline-offset-1 outline-n-weak"
              data-test="booking-scope-dropdown"
            >
              <template v-if="bookingResources.length">
                <button
                  type="button"
                  class="flex w-full items-center justify-between gap-2 rounded-lg px-2.5 py-2 text-left text-sm transition-colors hover:bg-n-alpha-2"
                  :class="
                    !selectedResourceIds.length
                      ? 'font-medium text-n-brand bg-n-alpha-1'
                      : 'text-n-slate-12'
                  "
                  data-test="booking-scope-option-all"
                  @click="clearBookingResources"
                >
                  <span class="truncate">
                    {{ t('CAPTAIN.AGENT_PAGE.BOOKING_SCOPE_ALL') }}
                  </span>
                  <Icon
                    v-if="!selectedResourceIds.length"
                    icon="i-lucide-check"
                    class="size-4 shrink-0 text-n-brand"
                  />
                </button>
                <div class="my-1 border-t border-n-weak" />
                <button
                  v-for="resource in bookingResources"
                  :key="resource.id"
                  type="button"
                  class="flex w-full items-center justify-between gap-2 rounded-lg px-2.5 py-2 text-left text-sm transition-colors hover:bg-n-alpha-2"
                  :class="
                    isResourceSelected(resource.id)
                      ? 'font-medium text-n-brand bg-n-alpha-1'
                      : 'text-n-slate-12'
                  "
                  :data-test="`booking-scope-option-${resource.id}`"
                  @click="toggleBookingResource(resource.id)"
                >
                  <span class="truncate">{{ resource.name }}</span>
                  <Icon
                    v-if="isResourceSelected(resource.id)"
                    icon="i-lucide-check"
                    class="size-4 shrink-0 text-n-brand"
                  />
                </button>
              </template>
              <p
                v-else
                class="mb-0 px-2.5 py-2 text-body-main text-n-slate-11"
                data-test="booking-scope-empty"
              >
                {{ t('CAPTAIN.AGENT_PAGE.BOOKING_SCOPE_EMPTY') }}
              </p>
            </div>

            <span class="text-body-main text-n-slate-11">
              {{ t('CAPTAIN.AGENT_PAGE.ALL_BOOKING_RESOURCES') }}
            </span>
          </div>
        </div>
      </section>

      <AgentModelBlock
        v-model:model="model"
        v-model:temperature="temperature"
        v-model:effort="thinkingEffort"
        :assistant="assistant"
        :disabled="!canEdit"
      />
      <AgentFollowUpsSummary
        :assistant="assistant"
        @open="emit('openFollowUps')"
      />
    </aside>
  </div>
</template>
