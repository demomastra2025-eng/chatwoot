<script setup>
import { computed } from 'vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { useI18n } from 'vue-i18n';
import { useKbd } from 'dashboard/composables/utils/useKbd';

const props = defineProps({
  // Insert is disabled while the draft is still animating in
  isGeneratingContent: {
    type: Boolean,
    default: false,
  },
  // A request is in flight: only «Отменить» is offered, and it cancels it
  isGenerating: {
    type: Boolean,
    default: false,
  },
  canCancel: {
    type: Boolean,
    default: true,
  },
});

// «Отменить» of a finished draft is `reject`: the draft is dropped
const emit = defineEmits(['submit', 'cancel', 'reject']);
const { t } = useI18n();

const shortcutKey = useKbd(['$mod', '+', 'enter']);

const insertTooltip = computed(() =>
  t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.INSERT_TOOLTIP', {
    shortcut: shortcutKey.value,
  })
);

const handleCancel = () => {
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
  <div class="flex items-center gap-2 px-3 pb-2.5 pt-0">
    <NextButton
      v-if="!isGenerating"
      :label="t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.INSERT')"
      variant="solid"
      color="blue"
      size="sm"
      :title="insertTooltip"
      :disabled="isGeneratingContent"
      data-test="copilot-panel-accept"
      @click="handleSubmit"
    />
    <NextButton
      :label="t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.CANCEL')"
      :variant="isGenerating ? 'ghost' : 'faded'"
      color="slate"
      size="sm"
      :disabled="isGenerating && !canCancel"
      data-test="copilot-panel-cancel"
      @click="handleCancel"
    />
  </div>
</template>
