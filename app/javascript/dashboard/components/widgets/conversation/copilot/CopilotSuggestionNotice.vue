<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { REPLY_SUGGESTION_NOTICE_KIND as KIND } from 'dashboard/composables/captain/constants';

// A notice is information for the manager, never a draft: it has no text to
// insert, copy or send. It is rendered above the reply box, outside the editor.
const props = defineProps({
  notice: { type: Object, required: true },
  stale: { type: Boolean, default: false },
});

const emit = defineEmits(['dismiss', 'retry']);

const { t } = useI18n();

const VIEW_BY_KIND = {
  [KIND.NO_REPLY]: {
    icon: 'i-lucide-message-square-off',
    card: 'bg-n-alpha-2 outline-n-weak',
    iconClass: 'text-n-slate-11',
  },
  [KIND.HUMAN_NEEDED]: {
    icon: 'i-lucide-user-round',
    card: 'bg-n-amber-3 outline-n-amber-5',
    iconClass: 'text-n-amber-11',
  },
  [KIND.FAILED]: {
    icon: 'i-lucide-circle-alert',
    card: 'bg-n-ruby-3 outline-n-ruby-5',
    iconClass: 'text-n-ruby-11',
  },
  [KIND.UNAVAILABLE]: {
    icon: 'i-lucide-info',
    card: 'bg-n-alpha-2 outline-n-weak',
    iconClass: 'text-n-slate-11',
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

// The agent's own words follow the title: «ИИ считает, что ответ не нужен: …»
const isDecision = computed(
  () =>
    props.notice.kind === KIND.NO_REPLY ||
    props.notice.kind === KIND.HUMAN_NEEDED
);

const body = computed(() => {
  if (reasonText.value) return reasonText.value;
  if (isDecision.value)
    return t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.NO_REASON');
  if (props.notice.reasonCode === 'voice_channel_unsupported') {
    return t(
      'CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.UNAVAILABLE_REASONS.VOICE_CHANNEL_UNSUPPORTED'
    );
  }
  return '';
});

// A real space between the title and the reason: template whitespace between
// two spans is dropped by the compiler.
const reasonLine = computed(() => ` ${body.value}`);

const agentName = computed(() => props.notice.agent?.name || '');
</script>

<template>
  <div
    class="mx-2 mb-2 flex items-start gap-2 rounded-xl px-3 py-2.5 outline outline-1 -outline-offset-1"
    :class="view.card"
    role="status"
    data-test="copilot-suggestion-notice"
    :data-kind="notice.kind"
  >
    <Icon
      :icon="view.icon"
      class="mt-0.5 size-4 shrink-0"
      :class="view.iconClass"
    />
    <div class="min-w-0 flex-1 space-y-0.5">
      <p
        class="mb-0 text-sm text-n-slate-12 break-words"
        data-test="copilot-notice-text"
      >
        <span class="font-medium">{{ title }}</span>
        <span v-if="body" data-test="copilot-notice-reason">{{
          reasonLine
        }}</span>
      </p>
      <p
        v-if="agentName"
        class="mb-0 text-xs text-n-slate-11"
        data-test="copilot-notice-agent"
      >
        {{
          t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.AGENT_LABEL', {
            agent: agentName,
          })
        }}
      </p>
      <p
        v-if="stale"
        class="mb-0 text-xs text-n-amber-11"
        data-test="copilot-notice-stale"
      >
        {{ t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.STALE_WARNING') }}
      </p>
    </div>
    <div class="flex shrink-0 items-center gap-1">
      <NextButton
        v-if="notice.canRetry"
        :label="t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.RETRY')"
        slate
        faded
        xs
        data-test="copilot-notice-retry"
        @click="emit('retry')"
      />
      <NextButton
        icon="i-lucide-x"
        slate
        ghost
        xs
        :aria-label="
          t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.DISMISS')
        "
        :title="t('CONVERSATION.REPLYBOX.COPILOT_SUGGESTION.NOTICE.DISMISS')"
        data-test="copilot-notice-dismiss"
        @click="emit('dismiss')"
      />
    </div>
  </div>
</template>
