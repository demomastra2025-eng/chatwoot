<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { REPLY_SUGGESTION_NOTICE_KIND as KIND } from 'dashboard/composables/captain/constants';

// A notice is information for the manager, never a draft: it has no text to
// insert, copy or send. It is rendered above the reply box, outside the editor.
// It says what happened in plain words: no agent, router or tool is named.
const props = defineProps({
  notice: { type: Object, required: true },
  stale: { type: Boolean, default: false },
});

const emit = defineEmits(['dismiss', 'retry']);

const { t } = useI18n();

// The card is neutral; only the icon in its circle carries the colour
const VIEW_BY_KIND = {
  [KIND.NO_REPLY]: {
    icon: 'i-lucide-message-square-off',
    circle: 'bg-n-alpha-2 text-n-slate-11',
  },
  [KIND.HUMAN_NEEDED]: {
    icon: 'i-lucide-user-round',
    circle: 'bg-n-amber-3 text-n-amber-11',
  },
  [KIND.FAILED]: {
    icon: 'i-lucide-circle-alert',
    circle: 'bg-n-ruby-3 text-n-ruby-11',
  },
  [KIND.UNAVAILABLE]: {
    icon: 'i-lucide-info',
    circle: 'bg-n-alpha-2 text-n-slate-11',
  },
};

const view = computed(
  () => VIEW_BY_KIND[props.notice.kind] || VIEW_BY_KIND[KIND.UNAVAILABLE]
);

const reasonText = computed(() => String(props.notice.reason || '').trim());

const title = computed(() => {
  switch (props.notice.kind) {
    case KIND.NO_REPLY:
      return t(
        'CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.NO_REPLY_TITLE'
      );
    case KIND.HUMAN_NEEDED:
      return t(
        'CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.HUMAN_NEEDED_TITLE'
      );
    case KIND.FAILED:
      return t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.FAILED_TITLE');
    default:
      return t(
        'CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.UNAVAILABLE_TITLE'
      );
  }
});

// The words of the decision follow the title: why no reply is needed, why a
// staff member is.
const isDecision = computed(
  () =>
    props.notice.kind === KIND.NO_REPLY ||
    props.notice.kind === KIND.HUMAN_NEEDED
);

const body = computed(() => {
  if (reasonText.value) return reasonText.value;
  if (isDecision.value) {
    return t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.NO_REASON');
  }
  if (props.notice.kind === KIND.FAILED) {
    return t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.FAILED_BODY');
  }
  if (props.notice.reasonCode === 'voice_channel_unsupported') {
    return t(
      'CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.UNAVAILABLE_REASONS.VOICE_CHANNEL_UNSUPPORTED'
    );
  }
  return '';
});
</script>

<template>
  <div
    class="mx-2 mb-2 flex items-start gap-3 rounded-xl border border-n-weak bg-n-solid-1 py-3 pl-3.5 pr-2 shadow-sm"
    role="status"
    data-test="copilot-suggestion-notice"
    :data-kind="notice.kind"
  >
    <span
      class="grid size-[30px] shrink-0 place-items-center rounded-full"
      :class="view.circle"
    >
      <Icon :icon="view.icon" class="size-4" />
    </span>
    <div class="min-w-0 flex-1 pt-px">
      <p
        class="mb-0 break-words text-sm font-medium leading-snug text-n-slate-12"
        data-test="copilot-notice-title"
      >
        {{ title }}
      </p>
      <p
        v-if="body"
        class="mb-0 mt-0.5 break-words text-[13px] leading-normal text-n-slate-11"
        data-test="copilot-notice-reason"
      >
        {{ body }}
      </p>
      <p
        v-if="stale"
        class="mb-0 mt-1 text-xs text-n-amber-11"
        data-test="copilot-notice-stale"
      >
        {{ t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.STALE_WARNING') }}
      </p>
      <div v-if="notice.canRetry" class="mt-2.5 flex gap-1">
        <NextButton
          :label="t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.RETRY')"
          variant="faded"
          color="slate"
          size="sm"
          data-test="copilot-notice-retry"
          @click="emit('retry')"
        />
      </div>
    </div>
    <NextButton
      icon="i-lucide-x"
      variant="ghost"
      color="slate"
      size="xs"
      class="-mt-0.5 shrink-0"
      :aria-label="t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.DISMISS')"
      :title="t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.DISMISS')"
      data-test="copilot-notice-dismiss"
      @click="emit('dismiss')"
    />
  </div>
</template>
