<script setup>
import { computed, h, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useToggle, useElementSize } from '@vueuse/core';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength, maxLength } from '@vuelidate/validators';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const props = defineProps({
  id: {
    type: Number,
    required: true,
  },
  title: {
    type: String,
    required: true,
  },
  description: {
    type: String,
    required: true,
  },
  instruction: {
    type: String,
    required: true,
  },
  tools: {
    type: Array,
    default: () => [],
  },
  enabled: {
    type: Boolean,
    default: true,
  },
  assistantId: {
    type: Number,
    default: null,
  },
  selectable: {
    type: Boolean,
    default: false,
  },
  isSelected: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['select', 'hover', 'delete', 'update']);

const { t } = useI18n();
const { formatMessage } = useMessageFormatter();
const SCENARIO_DESCRIPTION_MAX_LENGTH = 2000;
const SCENARIO_INSTRUCTION_MAX_LENGTH = 20_000;

const modelValue = computed({
  get: () => props.isSelected,
  set: () => emit('select', props.id),
});

const state = reactive({
  id: '',
  title: '',
  description: '',
  instruction: '',
  tools: [],
  enabled: true,
});

const instructionContentRef = ref();

const [isEditing, toggleEditing] = useToggle();
const [isInstructionExpanded, toggleInstructionExpanded] = useToggle();

const { height: contentHeight } = useElementSize(instructionContentRef);
const needsOverlay = computed(() => contentHeight.value > 160);

const startEdit = () => {
  Object.assign(state, {
    id: props.id,
    title: props.title,
    description: props.description,
    instruction: props.instruction,
    tools: props.tools,
    enabled: props.enabled,
  });
  toggleEditing(true);
};

const rules = {
  title: { required, minLength: minLength(1) },
  description: {
    required,
    maxLength: maxLength(SCENARIO_DESCRIPTION_MAX_LENGTH),
  },
  instruction: {
    required,
    maxLength: maxLength(SCENARIO_INSTRUCTION_MAX_LENGTH),
  },
};

const v$ = useVuelidate(rules, state);

const titleError = computed(() =>
  v$.value.title.$error
    ? t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.TITLE.ERROR')
    : ''
);

const descriptionError = computed(() =>
  v$.value.description.$error
    ? t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.DESCRIPTION.ERROR')
    : ''
);

const buildScenarioPayload = overrides => ({
  id: props.id,
  title: props.title,
  description: props.description,
  instruction: props.instruction,
  tools: props.tools,
  enabled: props.enabled,
  ...overrides,
});

const enabledLabel = computed(() =>
  props.enabled
    ? t('CAPTAIN.ASSISTANTS.SCENARIOS.STATUS.ENABLED')
    : t('CAPTAIN.ASSISTANTS.SCENARIOS.STATUS.DISABLED')
);

const onToggleEnabled = enabled => {
  emit('update', buildScenarioPayload({ enabled }));
};

const onClickUpdate = () => {
  v$.value.$touch();
  if (v$.value.$invalid) return;
  emit('update', { ...state });
  toggleEditing(false);
};

const instructionError = computed(() =>
  v$.value.instruction.$error
    ? t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.INSTRUCTION.ERROR')
    : ''
);

const LINK_INSTRUCTION_CLASS =
  '[&_a[href^="tool://"]]:text-n-iris-11 [&_a[href^="field://"]]:text-n-teal-11 [&_a:not([href^="tool://"]):not([href^="field://"])]:text-n-slate-12 [&_a]:pointer-events-none [&_a]:cursor-default';

const renderInstruction = instruction => () =>
  h('p', {
    class: `text-sm text-n-slate-12 py-4 mb-0 prose prose-sm min-w-0 break-words max-w-none ${LINK_INSTRUCTION_CLASS}`,
    innerHTML: instruction,
  });

const toolLabels = computed(() => ({
  search_documentation: t(
    'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.search_documentation.TITLE'
  ),
  faq_lookup: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.faq_lookup.TITLE'),
  add_contact_note: t(
    'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_contact_note.TITLE'
  ),
  add_private_note: t(
    'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_private_note.TITLE'
  ),
  add_label_to_conversation: t(
    'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.add_label_to_conversation.TITLE'
  ),
  update_priority: t(
    'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.update_priority.TITLE'
  ),
  resolve_conversation: t(
    'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.resolve_conversation.TITLE'
  ),
  handoff: t('CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.handoff.TITLE'),
}));

const humanizeToolId = toolId => toolLabels.value[toolId] || `@${toolId}`;
</script>

<template>
  <CardLayout
    selectable
    class="relative [&>div]:!py-4"
    :class="{
      '[&>div]:ltr:!pr-4 [&>div]:rtl:!pl-4': !isEditing,
      '[&>div]:ltr:!pr-10 [&>div]:rtl:!pl-10': isEditing,
      'opacity-80': !enabled && !isEditing,
    }"
    layout="row"
    @mouseenter="emit('hover', true)"
    @mouseleave="emit('hover', false)"
  >
    <div
      v-show="selectable && !isEditing"
      class="absolute top-[1.125rem] ltr:left-3 rtl:right-3"
    >
      <Checkbox v-model="modelValue" />
    </div>

    <div v-if="!isEditing" class="flex h-full flex-col w-full">
      <div class="flex items-start justify-between w-full gap-2">
        <div class="flex min-w-0 flex-col items-start">
          <div class="flex items-center gap-2 min-w-0">
            <span class="text-sm text-n-slate-12 font-medium truncate">
              {{ title }}
            </span>
            <span
              class="inline-flex shrink-0 rounded-full px-2 py-0.5 text-[0.6875rem] font-medium"
              :class="
                enabled
                  ? 'bg-n-brand/10 text-n-brand'
                  : 'bg-n-alpha-2 text-n-slate-11'
              "
            >
              {{ enabledLabel }}
            </span>
          </div>
          <span class="mt-2 text-sm text-n-slate-11">
            {{ description }}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <div class="flex items-center gap-2">
            <Switch
              :model-value="enabled"
              @click.stop
              @change="onToggleEnabled"
            />
          </div>
          <!-- <Button label="Test" slate xs ghost class="!text-sm" />
          <span class="w-px h-4 bg-n-weak" /> -->
          <Button icon="i-lucide-pen" slate xs ghost @click="startEdit" />
          <span class="w-px h-4 bg-n-weak" />
          <Button
            icon="i-lucide-trash"
            slate
            xs
            ghost
            @click="emit('delete', id)"
          />
        </div>
      </div>

      <div
        class="relative flex-1 overflow-hidden transition-all duration-300 ease-in-out group/expandable"
        :class="{ 'cursor-pointer': needsOverlay }"
        :style="{
          maxHeight: isInstructionExpanded ? `${contentHeight}px` : '10rem',
        }"
        @click="needsOverlay ? toggleInstructionExpanded() : null"
      >
        <div ref="instructionContentRef">
          <component
            :is="renderInstruction(formatMessage(instruction, false))"
          />
        </div>

        <div
          class="absolute bottom-0 w-full flex items-end justify-center text-xs text-n-slate-11 bg-gradient-to-t h-40 from-n-solid-2 via-n-solid-2 via-10% to-transparent transition-all duration-500 ease-in-out px-2 py-1 rounded pointer-events-none"
          :class="{
            'visible opacity-100': !isInstructionExpanded,
            'invisible opacity-0': isInstructionExpanded || !needsOverlay,
          }"
        >
          <Icon
            icon="i-lucide-chevron-down"
            class="text-n-slate-7 mb-4 size-4 group-hover/expandable:text-n-slate-11 transition-colors duration-200"
          />
        </div>
      </div>
      <span
        v-if="tools?.length"
        class="mt-3 text-sm text-n-slate-11 font-medium"
      >
        {{ t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.SUGGESTED.TOOLS_USED') }}
        {{ tools?.map(humanizeToolId).join(', ') }}
      </span>
    </div>
    <div v-else class="overflow-hidden flex flex-col gap-4 w-full">
      <div class="flex items-center justify-between gap-3">
        <span class="text-sm text-n-slate-12 font-medium">
          {{ t('CAPTAIN.ASSISTANTS.SCENARIOS.TOGGLE.LABEL') }}
        </span>
        <div class="flex items-center gap-2">
          <span class="text-sm text-n-slate-11">
            {{
              state.enabled
                ? t('CAPTAIN.ASSISTANTS.SCENARIOS.STATUS.ENABLED')
                : t('CAPTAIN.ASSISTANTS.SCENARIOS.STATUS.DISABLED')
            }}
          </span>
          <Switch v-model="state.enabled" />
        </div>
      </div>
      <Input
        v-model="state.title"
        :label="t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.TITLE.LABEL')"
        :placeholder="
          t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.TITLE.PLACEHOLDER')
        "
        :message="titleError"
        :message-type="titleError ? 'error' : 'info'"
      />

      <TextArea
        v-model="state.description"
        :label="
          t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.DESCRIPTION.LABEL')
        "
        :placeholder="
          t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.DESCRIPTION.PLACEHOLDER')
        "
        :message="descriptionError"
        :message-type="descriptionError ? 'error' : 'info'"
        :max-length="SCENARIO_DESCRIPTION_MAX_LENGTH"
        show-character-count
      />
      <Editor
        v-model="state.instruction"
        override-line-breaks
        :label="
          t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.INSTRUCTION.LABEL')
        "
        :placeholder="
          t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.INSTRUCTION.PLACEHOLDER')
        "
        :message="instructionError"
        :message-type="instructionError ? 'error' : 'info'"
        :max-length="SCENARIO_INSTRUCTION_MAX_LENGTH"
        enable-captain-tools
        enable-captain-fields
        :captain-context-assistant-id="assistantId"
      />
      <div class="flex items-center gap-3">
        <Button
          faded
          slate
          sm
          :label="t('CAPTAIN.ASSISTANTS.SCENARIOS.UPDATE.CANCEL')"
          @click="toggleEditing(false)"
        />
        <Button
          sm
          :label="t('CAPTAIN.ASSISTANTS.SCENARIOS.UPDATE.UPDATE')"
          @click="onClickUpdate"
        />
      </div>
    </div>
  </CardLayout>
</template>
