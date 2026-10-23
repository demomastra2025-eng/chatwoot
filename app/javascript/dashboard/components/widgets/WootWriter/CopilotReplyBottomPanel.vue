<script setup>
import { computed } from 'vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { useI18n } from 'vue-i18n';
import { useKbd } from 'dashboard/composables/utils/useKbd';

const props = defineProps({
  // Insert is disabled: generating, or the draft is still animating in
  isGeneratingContent: {
    type: Boolean,
    default: false,
  },
  // A request is in flight: the left button cancels it instead of rejecting
  isGenerating: {
    type: Boolean,
    default: false,
  },
  canCancel: {
    type: Boolean,
    default: true,
  },
  isQueued: {
    type: Boolean,
    default: false,
  },
  elapsedSeconds: {
    type: Number,
    default: null,
  },
  budgetSeconds: {
    type: Number,
    default: 60,
  },
});

const emit = defineEmits(['submit', 'cancel', 'reject']);
const { t } = useI18n();

const shortcutKey = useKbd(['$mod', '+', 'enter']);

const acceptLabel = computed(() => {
  return `${t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.INSERT_AND_EDIT')}  (${shortcutKey.value})`;
});

const leftLabel = computed(() =>
  props.isGenerating
    ? t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.CANCEL')
    : t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.REJECT')
);

const progressText = computed(() => {
  if (!props.isGenerating) return '';
  if (props.isQueued)
    return t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.QUEUED');
  if (props.elapsedSeconds === null) return '';
  return t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.ELAPSED', {
    elapsed: props.elapsedSeconds,
    budget: props.budgetSeconds,
  });
});

const handleLeftClick = () => {
  if (props.isGenerating) {
    emit('cancel');
  } else {
    emit('reject');
  }
};

const handleSubmit = () => {
  emit('submit');
};
</script>

<template>
  <div class="flex justify-between items-center gap-2 px-3 pb-2.5 pt-0">
    <NextButton
      :label="leftLabel"
      slate
      link
      class="!px-1 hover:!no-underline"
      sm
      :disabled="isGenerating && !canCancel"
      data-test="copilot-panel-left"
      @click="handleLeftClick"
    />
    <span
      v-if="progressText"
      class="min-w-0 truncate text-xs text-n-slate-11"
      data-test="copilot-panel-progress"
    >
      {{ progressText }}
    </span>
    <NextButton
      :label="acceptLabel"
      class="bg-n-iris-9 text-white"
      solid
      sm
      :disabled="isGeneratingContent"
      data-test="copilot-panel-accept"
      @click="handleSubmit"
    />
  </div>
</template>
