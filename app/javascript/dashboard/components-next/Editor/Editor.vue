<script setup>
import {
  computed,
  ref,
  watch,
  useSlots,
  onBeforeUnmount,
  onMounted,
} from 'vue';

import WootEditor from 'dashboard/components/widgets/WootWriter/Editor.vue';

const props = defineProps({
  modelValue: { type: String, default: '' },
  editorKey: { type: String, default: '' },
  label: { type: String, default: '' },
  placeholder: { type: String, default: '' },
  focusOnMount: { type: Boolean, default: false },
  maxLength: { type: Number, default: 200 },
  showCharacterCount: { type: Boolean, default: true },
  disabled: { type: Boolean, default: false },
  message: { type: String, default: '' },
  messageType: {
    type: String,
    default: 'info',
    validator: value => ['info', 'error', 'success'].includes(value),
  },
  enableVariables: { type: Boolean, default: false },
  enableCannedResponses: { type: Boolean, default: true },
  enableCaptainTools: { type: Boolean, default: false },
  enableCaptainFields: { type: Boolean, default: false },
  captainContextAssistantId: { type: Number, default: null },
  captainContextAccess: { type: Object, default: null },
  captainToolAccess: { type: Object, default: null },
  captainToolScope: { type: String, default: 'agent' },
  signature: { type: String, default: '' },
  allowSignature: { type: Boolean, default: false },
  sendWithSignature: { type: Boolean, default: false },
  channelType: { type: String, default: '' },
  medium: { type: String, default: '' },
  overrideLineBreaks: { type: Boolean, default: false },
  autoHeight: { type: Boolean, default: false },
  minHeight: { type: String, default: '10rem' },
  maxHeight: { type: String, default: '32rem' },
});

const emit = defineEmits(['update:modelValue', 'executeCopilotAction']);

const AUTO_HEIGHT_STORAGE_PREFIX = 'captain:editor-height:';
const DEFAULT_EDITOR_HEIGHT = 240;
const MIN_EDITOR_HEIGHT = 140;
const MAX_EDITOR_HEIGHT = 1200;

const slots = useSlots();

const isFocused = ref(false);
const editorHeight = ref(DEFAULT_EDITOR_HEIGHT);
const isResizing = ref(false);
const resizeStartY = ref(0);
const resizeStartHeight = ref(DEFAULT_EDITOR_HEIGHT);

const normalizedModelValue = computed(() => props.modelValue || '');
const characterCount = computed(() => normalizedModelValue.value.length);
const storageKey = computed(
  () =>
    `${AUTO_HEIGHT_STORAGE_PREFIX}${props.editorKey || props.label || 'default'}`
);
const clampEditorHeight = height =>
  Math.min(
    Math.max(Number(height) || DEFAULT_EDITOR_HEIGHT, MIN_EDITOR_HEIGHT),
    MAX_EDITOR_HEIGHT
  );

const readStoredEditorHeight = () => {
  try {
    return window.localStorage.getItem(storageKey.value);
  } catch {
    return null;
  }
};

const writeStoredEditorHeight = () => {
  try {
    window.localStorage.setItem(storageKey.value, String(editorHeight.value));
  } catch {
    // Storage can be unavailable in private/locked-down browser contexts.
  }
};

const removeStoredEditorHeight = () => {
  try {
    window.localStorage.removeItem(storageKey.value);
  } catch {
    // Storage can be unavailable in private/locked-down browser contexts.
  }
};

const loadStoredEditorHeight = () => {
  if (!props.autoHeight) return;
  const storedHeight = readStoredEditorHeight();
  editorHeight.value = clampEditorHeight(storedHeight || DEFAULT_EDITOR_HEIGHT);
};

const saveEditorHeight = () => {
  if (!props.autoHeight) return;
  writeStoredEditorHeight();
};

const clearDragStyles = () => {
  Object.assign(document.body.style, { cursor: '', userSelect: '' });
};

const getClientY = event => event.touches?.[0]?.clientY || event.clientY;

const startResize = event => {
  if (!props.autoHeight || props.disabled) return;
  isResizing.value = true;
  resizeStartY.value = getClientY(event);
  resizeStartHeight.value = editorHeight.value;
  Object.assign(document.body.style, {
    cursor: 'row-resize',
    userSelect: 'none',
  });
};

const onResizeMove = event => {
  if (!isResizing.value) return;
  if (event.touches) event.preventDefault();
  editorHeight.value = clampEditorHeight(
    resizeStartHeight.value + getClientY(event) - resizeStartY.value
  );
};

const onResizeEnd = () => {
  if (!isResizing.value) return;
  isResizing.value = false;
  clearDragStyles();
  saveEditorHeight();
};

const resetEditorHeight = () => {
  if (!props.autoHeight) return;
  editorHeight.value = DEFAULT_EDITOR_HEIGHT;
  removeStoredEditorHeight();
};

const autoHeightStyle = computed(() => {
  if (!props.autoHeight) return undefined;

  return {
    '--editor-min-height': props.minHeight,
    '--editor-max-height': props.maxHeight,
    '--editor-height': `${editorHeight.value}px`,
  };
});

const messageClass = computed(() => {
  switch (props.messageType) {
    case 'error':
      return 'text-n-ruby-9 dark:text-n-ruby-9';
    case 'success':
      return 'text-n-teal-10 dark:text-n-teal-10';
    default:
      return 'text-n-slate-11 dark:text-n-slate-11';
  }
});

const handleInput = value => {
  if (!props.disabled) {
    emit('update:modelValue', value);
  }
};

const handleFocus = () => {
  if (!props.disabled) {
    isFocused.value = true;
  }
};

const handleBlur = () => {
  if (!props.disabled) {
    isFocused.value = false;
  }
};

watch(
  () => props.modelValue,
  newValue => {
    if (props.maxLength && props.showCharacterCount && !slots.actions) {
      const nextValue = newValue || '';
      if (characterCount.value >= props.maxLength) {
        emit('update:modelValue', nextValue.slice(0, props.maxLength));
      }
    }
  }
);

watch(() => [props.autoHeight, storageKey.value], loadStoredEditorHeight);

onMounted(() => {
  loadStoredEditorHeight();
  window.addEventListener('mousemove', onResizeMove);
  window.addEventListener('mouseup', onResizeEnd);
  window.addEventListener('touchmove', onResizeMove, { passive: false });
  window.addEventListener('touchend', onResizeEnd);
  window.addEventListener('touchcancel', onResizeEnd);
});

onBeforeUnmount(() => {
  window.removeEventListener('mousemove', onResizeMove);
  window.removeEventListener('mouseup', onResizeEnd);
  window.removeEventListener('touchmove', onResizeMove);
  window.removeEventListener('touchend', onResizeEnd);
  window.removeEventListener('touchcancel', onResizeEnd);
  clearDragStyles();
});
</script>

<template>
  <div class="flex flex-col min-w-0 gap-1">
    <label v-if="label" class="mb-0.5 text-sm font-medium text-n-slate-12">
      {{ label }}
    </label>
    <div
      class="flex flex-col w-full gap-2 px-3 py-3 transition-all duration-500 ease-in-out border rounded-lg editor-wrapper bg-n-alpha-black2"
      :class="[
        {
          'editor-wrapper--auto-height': autoHeight,
          'cursor-not-allowed opacity-50 pointer-events-none !bg-n-alpha-black2 disabled:border-n-weak dark:disabled:border-n-weak':
            disabled,
          'border-n-brand dark:border-n-brand': isFocused,
          'hover:border-n-slate-6 dark:hover:border-n-slate-6 border-n-weak dark:border-n-weak':
            !isFocused && messageType !== 'error',
          'border-n-ruby-8 dark:border-n-ruby-8 hover:border-n-ruby-9 dark:hover:border-n-ruby-9':
            messageType === 'error' && !isFocused,
        },
      ]"
      :style="autoHeightStyle"
    >
      <WootEditor
        :editor-id="editorKey"
        :model-value="normalizedModelValue"
        :placeholder="placeholder"
        :focus-on-mount="focusOnMount"
        :disabled="disabled"
        :class="{ 'auto-height-editor-wrapper': autoHeight }"
        :style="autoHeightStyle"
        :enable-variables="enableVariables"
        :enable-canned-responses="enableCannedResponses"
        :enable-captain-tools="enableCaptainTools"
        :enable-captain-fields="enableCaptainFields"
        :captain-context-assistant-id="captainContextAssistantId"
        :captain-context-access="captainContextAccess"
        :captain-tool-access="captainToolAccess"
        :captain-tool-scope="captainToolScope"
        :signature="signature"
        :allow-signature="allowSignature"
        :send-with-signature="sendWithSignature"
        :channel-type="channelType"
        :medium="medium"
        :override-line-breaks="overrideLineBreaks"
        @input="handleInput"
        @focus="handleFocus"
        @blur="handleBlur"
        @execute-copilot-action="
          (...args) => emit('executeCopilotAction', ...args)
        "
      />
      <div
        v-if="autoHeight"
        class="group -mx-1 -mb-2 flex h-5 cursor-row-resize select-none items-center justify-center rounded-b-lg text-n-slate-9 hover:bg-n-alpha-2"
        :class="{ 'bg-n-alpha-2 text-n-slate-11': isResizing }"
        @mousedown="startResize"
        @touchstart.prevent="startResize"
        @dblclick="resetEditorHeight"
      >
        <div class="h-0.5 w-10 rounded-full bg-current opacity-60" />
      </div>
      <div
        v-if="showCharacterCount || slots.actions"
        class="flex items-center justify-end h-4 ltr:right-3 rtl:left-3"
      >
        <span
          v-if="showCharacterCount && !slots.actions"
          class="text-xs tabular-nums text-n-slate-10"
        >
          {{ characterCount }} / {{ maxLength }}
        </span>
        <slot v-else name="actions" />
      </div>
    </div>
    <p
      v-if="message"
      class="min-w-0 mt-1 mb-0 text-xs truncate transition-all duration-500 ease-in-out"
      :class="messageClass"
    >
      {{ message }}
    </p>
  </div>
</template>

<style lang="scss" scoped>
.editor-wrapper {
  ::v-deep {
    .ProseMirror-menubar-wrapper {
      .ProseMirror.ProseMirror-woot-style {
        p {
          @apply first:mt-0 !important;
        }

        .empty-node {
          @apply m-0 !important;

          &::before {
            @apply text-n-slate-11 dark:text-n-slate-11;
          }
        }
      }

      .ProseMirror-menubar {
        width: fit-content !important;
        position: relative !important;
        top: unset !important;
        @apply ltr:left-[-0.188rem] rtl:right-[-0.188rem] !important;
      }
    }
  }
}

.editor-wrapper--auto-height {
  ::v-deep(.ProseMirror.ProseMirror-woot-style) {
    height: var(--editor-height, 15rem);
    min-height: var(--editor-min-height, 10rem);
    max-height: none !important;
    @apply overflow-auto;
  }
}
</style>
