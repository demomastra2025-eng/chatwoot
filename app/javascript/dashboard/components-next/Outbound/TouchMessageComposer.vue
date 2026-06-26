<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import WhatsAppTemplateParser from 'dashboard/components-next/whatsapp/WhatsAppTemplateParser.vue';
import WootMessageEditor from 'dashboard/components/widgets/WootWriter/Editor.vue';

const props = defineProps({
  activeContentTabIndex: {
    type: Number,
    default: 0,
  },
  allowAiAuthoring: {
    type: Boolean,
    default: true,
  },
  attachments: {
    type: Array,
    default: () => [],
  },
  availableFieldScopes: {
    type: Array,
    default: () => [],
  },
  availableVariablePrefixes: {
    type: Array,
    default: () => [],
  },
  body: {
    type: String,
    default: '',
  },
  bodyEditorId: {
    type: String,
    required: true,
  },
  bodyLabel: {
    type: String,
    default: '',
  },
  bodyPlaceholder: {
    type: String,
    default: '',
  },
  cannedMenuVisibleItems: {
    type: Number,
    default: 3,
  },
  channelType: {
    type: String,
    default: '',
  },
  contentKind: {
    type: String,
    default: 'free_text',
  },
  contentModeTabId: {
    type: String,
    default: '',
  },
  contentModeTabs: {
    type: Array,
    default: () => [],
  },
  conversationId: {
    type: [Number, String],
    default: null,
  },
  editorMessage: {
    type: String,
    default: '',
  },
  editorMessageType: {
    type: String,
    default: 'info',
  },
  freeTextTemplateOptions: {
    type: Array,
    default: () => [],
  },
  enableAttachments: {
    type: Boolean,
    default: true,
  },
  enableCannedResponses: {
    type: Boolean,
    default: true,
  },
  enableCaptainFields: {
    type: Boolean,
    default: true,
  },
  enableVariables: {
    type: Boolean,
    default: true,
  },
  instructions: {
    type: String,
    default: '',
  },
  instructionsEditorId: {
    type: String,
    required: true,
  },
  instructionsPlaceholder: {
    type: String,
    default: '',
  },
  idPrefix: {
    type: String,
    default: 'touch-message',
  },
  isDraggingAttachment: {
    type: Boolean,
    default: false,
  },
  isUploadingAttachment: {
    type: Boolean,
    default: false,
  },
  medium: {
    type: String,
    default: '',
  },
  selectedTemplate: {
    type: Object,
    default: null,
  },
  selectedTemplateGroup: {
    type: Object,
    default: null,
  },
  showFieldsButton: {
    type: Boolean,
    default: true,
  },
  templateEmptyDescription: {
    type: String,
    default: '',
  },
  templateEmptyTitle: {
    type: String,
    default: '',
  },
  templateLanguage: {
    type: String,
    default: '',
  },
  templateLanguageOptions: {
    type: Array,
    default: () => [],
  },
  templateName: {
    type: String,
    default: '',
  },
  templateOptions: {
    type: Array,
    default: () => [],
  },
  templateParams: {
    type: Object,
    default: () => ({}),
  },
  useAiAuthoring: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits([
  'attachmentFiles',
  'contentTabChange',
  'removeAttachment',
  'setAttachmentDragging',
  'templateStateChange',
  'update:body',
  'update:instructions',
  'update:templateLanguage',
  'update:templateName',
  'update:useAiAuthoring',
]);

const { t } = useI18n();
const bodyEditorRef = ref(null);
const instructionsEditorRef = ref(null);
const templateParserRef = ref(null);
const attachmentFileInput = ref(null);
const selectedFreeTextTemplate = ref('');
const FIELD_REFERENCE_MARKER = '$';
const freeTextTemplateId = computed(
  () => `${props.idPrefix}-free-text-template`
);
const templateNameId = computed(() => `${props.idPrefix}-template-name`);
const templateLanguageId = computed(
  () => `${props.idPrefix}-template-language`
);

const hasContentTabs = computed(() => props.contentModeTabs.length > 0);
const isChannelTemplate = computed(
  () => props.contentKind === 'channel_template'
);
const showFreeTextTemplatePicker = computed(
  () =>
    !isChannelTemplate.value &&
    !props.useAiAuthoring &&
    props.freeTextTemplateOptions.length > 0
);
const templateEmptyTitleText = computed(
  () =>
    props.templateEmptyTitle ||
    t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_EMPTY')
);
const templateEmptyDescriptionText = computed(
  () =>
    props.templateEmptyDescription ||
    t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_EMPTY_DESCRIPTION')
);
const conversationIdValue = computed(() => {
  const numericId = Number(props.conversationId);
  return Number.isFinite(numericId) && numericId > 0 ? numericId : null;
});
const parserState = computed(() => ({
  processedParams: templateParserRef.value?.processedParams || {},
  rawRenderedTemplate: templateParserRef.value?.rawRenderedTemplate || '',
}));
const isTemplateInvalid = computed(
  () => templateParserRef.value?.isFormInvalid === true
);
const hasValidTemplate = computed(
  () =>
    !isChannelTemplate.value || templateParserRef.value?.isFormInvalid === false
);

const aiToggleButtonClass = isEnabled => {
  return isEnabled
    ? '!bg-n-violet-3 !text-n-violet-9 hover:enabled:!bg-n-violet-4 focus-visible:!bg-n-violet-4 !outline-transparent'
    : '';
};

const editorClass = isAiAuthoring => {
  return [
    'touch-rich-editor w-full min-w-0 max-w-full overflow-visible rounded-xl px-3 py-2 transition-all duration-200',
    'touch-message-composer-editor',
    isAiAuthoring
      ? 'bg-n-violet-3 ring-1 ring-inset ring-n-violet-6/20'
      : 'bg-n-alpha-black2 outline outline-1 outline-n-weak dark:outline-n-strong',
  ].join(' ');
};

const formatAttachmentSize = size => {
  const byteSize = Number(size || 0);
  if (!Number.isFinite(byteSize) || byteSize <= 0) return '';
  if (byteSize < 1024 * 1024) return `${Math.ceil(byteSize / 1024)} KB`;
  return `${(byteSize / (1024 * 1024)).toFixed(1)} MB`;
};

const openFieldsMenu = () => {
  const activeEditor = props.useAiAuthoring
    ? instructionsEditorRef.value
    : bodyEditorRef.value;

  activeEditor?.openCaptainReferenceMenu?.('fields', { insert: true });
};

const openAttachmentPicker = () => {
  attachmentFileInput.value?.click();
};

const applyFreeTextTemplate = templateValue => {
  selectedFreeTextTemplate.value = templateValue || '';
  if (!templateValue) return;

  const selectedTemplate = props.freeTextTemplateOptions.find(
    template => template.value === templateValue
  );

  if (!selectedTemplate) return;

  emit('update:useAiAuthoring', false);
  emit('update:body', String(selectedTemplate.content || ''));
};

const handleAttachmentUpload = event => {
  const files = Array.from(event.target.files || []);
  event.target.value = '';
  emit('attachmentFiles', files);
};

const handleAttachmentDrop = event => {
  emit('setAttachmentDragging', false);
  emit('attachmentFiles', Array.from(event.dataTransfer?.files || []));
};

const validateTemplate = async () => {
  if (!isChannelTemplate.value) return true;
  return (await templateParserRef.value?.v$?.$validate?.()) ?? true;
};

const isTemplateReady = () => hasValidTemplate.value;

watch(
  () => JSON.stringify(parserState.value),
  payload => {
    if (!isChannelTemplate.value || !templateParserRef.value) {
      return;
    }

    emit('templateStateChange', JSON.parse(payload || '{}'));
  }
);

watch(
  () => props.body,
  value => {
    if (!selectedFreeTextTemplate.value) return;

    const selectedTemplate = props.freeTextTemplateOptions.find(
      template => template.value === selectedFreeTextTemplate.value
    );
    if (selectedTemplate && selectedTemplate.content === value) return;

    selectedFreeTextTemplate.value = '';
  }
);

defineExpose({
  hasValidTemplate,
  isTemplateInvalid,
  isTemplateReady,
  openFieldsMenu,
  parserState,
  validateTemplate,
});
</script>

<template>
  <div class="grid gap-4">
    <div v-if="hasContentTabs" class="rounded-xl bg-n-alpha-black2 p-1">
      <TabBar
        :key="
          contentModeTabId || `touch-message-content-${activeContentTabIndex}`
        "
        :tabs="contentModeTabs"
        :initial-active-tab="activeContentTabIndex"
        @tab-changed="$emit('contentTabChange', $event)"
      />
    </div>

    <template v-if="isChannelTemplate">
      <slot name="template-controls-before" />

      <div v-if="templateOptions.length" class="grid gap-4">
        <div class="flex flex-col gap-1">
          <label
            :for="templateNameId"
            class="mb-0.5 text-sm font-medium text-n-slate-12"
          >
            {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE') }}
          </label>
          <ComboBox
            :id="templateNameId"
            :model-value="templateName"
            :options="templateOptions"
            :placeholder="
              $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_PLACEHOLDER')
            "
            class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
            @update:model-value="$emit('update:templateName', $event)"
          />
        </div>

        <div v-if="selectedTemplateGroup" class="flex flex-col gap-1">
          <label
            :for="templateLanguageId"
            class="mb-0.5 text-sm font-medium text-n-slate-12"
          >
            {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_LANGUAGE') }}
          </label>
          <ComboBox
            :id="templateLanguageId"
            :model-value="templateLanguage"
            :options="templateLanguageOptions"
            :placeholder="
              $t(
                'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_LANGUAGE_PLACEHOLDER'
              )
            "
            class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
            @update:model-value="$emit('update:templateLanguage', $event)"
          />
        </div>

        <WhatsAppTemplateParser
          v-if="selectedTemplate"
          ref="templateParserRef"
          :key="`${templateName}-${templateLanguage}`"
          :template="selectedTemplate"
          :initial-processed-params="templateParams"
        />
      </div>

      <div
        v-else
        class="rounded-xl border border-dashed border-n-weak bg-n-solid-1 px-4 py-5"
      >
        <p class="mb-1 text-sm font-medium text-n-slate-12">
          {{ templateEmptyTitleText }}
        </p>
        <p class="mb-0 text-sm text-n-slate-11">
          {{ templateEmptyDescriptionText }}
        </p>
      </div>
    </template>

    <template v-else>
      <div class="grid grid-cols-[1fr_auto_1fr] items-center gap-3">
        <p class="mb-0 text-sm font-medium text-n-slate-12">
          {{ bodyLabel || $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.BODY') }}
        </p>
        <Button
          v-if="showFieldsButton"
          size="sm"
          color="slate"
          variant="faded"
          class="!px-3"
          @mousedown.prevent
          @click="openFieldsMenu"
        >
          <span class="flex min-w-0 truncate">
            <span class="font-semibold text-n-brand">
              {{ FIELD_REFERENCE_MARKER }}
            </span>
            <span class="min-w-0 truncate">
              {{ $t('CAPTAIN.ASSISTANTS.FORM.REFERENCE_ACTIONS.FIELDS') }}
            </span>
          </span>
        </Button>
        <div class="flex justify-end">
          <Button
            v-if="allowAiAuthoring"
            v-tooltip.top-end="
              $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.AI_AGENT')
            "
            icon="i-woot-captain"
            :variant="useAiAuthoring ? 'solid' : 'faded'"
            color="slate"
            size="sm"
            :aria-pressed="useAiAuthoring"
            :class="aiToggleButtonClass(useAiAuthoring)"
            @click="$emit('update:useAiAuthoring', !useAiAuthoring)"
          />
        </div>
      </div>

      <div v-if="showFreeTextTemplatePicker" class="flex flex-col gap-1">
        <label
          :for="freeTextTemplateId"
          class="mb-0.5 text-sm font-medium text-n-slate-12"
        >
          {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.FREE_TEXT_TEMPLATE') }}
        </label>
        <ComboBox
          :id="freeTextTemplateId"
          :model-value="selectedFreeTextTemplate"
          :options="freeTextTemplateOptions"
          :placeholder="
            $t(
              'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.FREE_TEXT_TEMPLATE_PLACEHOLDER'
            )
          "
          class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
          @update:model-value="applyFreeTextTemplate"
        />
      </div>

      <WootMessageEditor
        v-if="!useAiAuthoring"
        ref="bodyEditorRef"
        :model-value="body"
        :editor-id="bodyEditorId"
        class="touch-message-composer-editor"
        :class="[editorClass(false)]"
        :channel-type="channelType"
        :conversation-id="conversationIdValue"
        :medium="medium"
        :allowed-variable-prefixes="availableVariablePrefixes"
        :allowed-field-scopes="availableFieldScopes"
        :enable-variables="enableVariables"
        :enable-captain-fields="enableCaptainFields"
        :enable-canned-responses="enableCannedResponses"
        canned-menu-placement="bottom"
        :canned-menu-visible-items="cannedMenuVisibleItems"
        :placeholder="
          bodyPlaceholder ||
          $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.BODY_PLACEHOLDER')
        "
        @update:model-value="$emit('update:body', $event)"
      />

      <WootMessageEditor
        v-else
        ref="instructionsEditorRef"
        :model-value="instructions"
        :editor-id="instructionsEditorId"
        class="touch-message-composer-editor"
        :class="[editorClass(true)]"
        :channel-type="channelType"
        :conversation-id="conversationIdValue"
        :medium="medium"
        :allowed-variable-prefixes="availableVariablePrefixes"
        :allowed-field-scopes="availableFieldScopes"
        :enable-variables="enableVariables"
        :enable-captain-fields="enableCaptainFields"
        :enable-canned-responses="enableCannedResponses"
        canned-menu-placement="bottom"
        :canned-menu-visible-items="cannedMenuVisibleItems"
        :placeholder="
          instructionsPlaceholder ||
          $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.INSTRUCTIONS_PLACEHOLDER')
        "
        @update:model-value="$emit('update:instructions', $event)"
      />

      <p
        v-if="editorMessage"
        class="mb-0 text-xs"
        :class="
          editorMessageType === 'error' ? 'text-n-ruby-9' : 'text-n-slate-11'
        "
      >
        {{ editorMessage }}
      </p>
    </template>

    <div v-if="enableAttachments" class="grid gap-3">
      <input
        ref="attachmentFileInput"
        type="file"
        multiple
        class="hidden"
        @change="handleAttachmentUpload"
      />

      <button
        type="button"
        class="group flex w-full items-center gap-4 rounded-xl border border-dashed px-4 py-4 text-left transition-all duration-200"
        :class="[
          isDraggingAttachment
            ? 'border-n-brand bg-n-brand/5'
            : 'border-n-slate-6 bg-n-alpha-black2 hover:border-n-brand/70 hover:bg-n-brand/5',
          isUploadingAttachment ? 'cursor-wait opacity-80' : 'cursor-pointer',
        ]"
        :disabled="isUploadingAttachment"
        @click="openAttachmentPicker"
        @dragenter.prevent="$emit('setAttachmentDragging', true)"
        @dragover.prevent="$emit('setAttachmentDragging', true)"
        @dragleave.prevent="$emit('setAttachmentDragging', false)"
        @drop.prevent="handleAttachmentDrop"
      >
        <span
          class="flex size-11 shrink-0 items-center justify-center rounded-xl bg-n-brand/10 text-n-brand transition-colors group-hover:bg-n-brand/15"
        >
          <span class="i-lucide-upload-cloud size-5" />
        </span>
        <span class="min-w-0 flex-1">
          <span class="block text-sm font-medium text-n-slate-12">
            {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.TITLE') }}
          </span>
          <span class="mt-1 block text-xs leading-5 text-n-slate-10">
            {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.DROP_HINT') }}
          </span>
        </span>
        <span
          class="hidden shrink-0 rounded-lg bg-n-alpha-black2 px-3 py-1 text-xs font-medium text-n-slate-11 md:inline-flex"
        >
          {{
            isUploadingAttachment
              ? $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.UPLOADING')
              : $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.ADD')
          }}
        </span>
      </button>

      <p class="mb-0 text-xs leading-5 text-n-slate-10">
        {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.DESCRIPTION') }}
      </p>

      <div v-if="attachments.length" class="grid gap-2">
        <div
          v-for="attachment in attachments"
          :key="attachment.blobId"
          class="flex items-center gap-3 rounded-xl border border-n-weak bg-n-solid-1 px-3 py-2"
        >
          <span class="i-lucide-file-check-2 size-4 shrink-0 text-n-slate-11" />
          <div class="min-w-0 flex-1">
            <p class="mb-0 truncate text-sm font-medium text-n-slate-12">
              {{ attachment.fileName }}
            </p>
            <p
              v-if="
                formatAttachmentSize(attachment.fileSize) ||
                attachment.contentType
              "
              class="mb-0 truncate text-xs text-n-slate-10"
            >
              {{
                formatAttachmentSize(attachment.fileSize) ||
                attachment.contentType
              }}
            </p>
          </div>
          <Button
            icon="i-lucide-x"
            size="xs"
            color="slate"
            variant="ghost"
            :aria-label="
              $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.REMOVE')
            "
            @click="$emit('removeAttachment', attachment.blobId)"
          />
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.touch-message-composer-editor {
  min-height: 13rem;
}

.touch-rich-editor :deep(.ProseMirror-menubar-wrapper),
.touch-rich-editor :deep(.ProseMirror),
.touch-rich-editor :deep(.ProseMirror-menubar) {
  min-width: 0;
  width: 100%;
  max-width: 100%;
}

.touch-message-composer-editor :deep(.ProseMirror) {
  min-height: 8.5rem;
}

.touch-rich-editor {
  overflow: visible;
}

.touch-rich-editor :deep(.mention--box),
.touch-rich-editor :deep(.copilot-editor-menu) {
  z-index: 70;
}
</style>
