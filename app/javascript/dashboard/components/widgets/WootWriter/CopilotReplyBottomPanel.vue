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
  // The run left only actions and no draft: only «Отменить» is offered, and it
  // declines the actions (`reject`); `canCancel` tells whether any is left
  actionsOnly: {
    type: Boolean,
    default: false,
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

const hasInsert = computed(() => !props.isGenerating && !props.actionsOnly);
const cancelDisabled = computed(
  () => (props.isGenerating || props.actionsOnly) && !props.canCancel
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
      v-if="hasInsert"
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
      :disabled="cancelDisabled"
      data-test="copilot-panel-cancel"
      @click="handleCancel"
    />
  </div>
</template>
