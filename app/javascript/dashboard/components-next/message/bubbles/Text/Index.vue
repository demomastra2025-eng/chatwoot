<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import BaseBubble from 'next/message/bubbles/Base.vue';
import FormattedContent from './FormattedContent.vue';
import AttachmentChips from 'next/message/chips/AttachmentChips.vue';
import CaptainToolExecutionGroup from 'dashboard/components-next/message/CaptainToolExecutionGroup.vue';
import TranslationToggle from 'dashboard/components-next/message/TranslationToggle.vue';
import { MESSAGE_TYPES } from '../../constants';
import { useMessageContext } from '../../provider.js';
import { useTranslations } from 'dashboard/composables/useTranslations';

const {
  content,
  attachments,
  contentAttributes,
  messageType,
  additionalAttributes,
} = useMessageContext();
const { t } = useI18n();

const { hasTranslations, translationContent } =
  useTranslations(contentAttributes);

const renderOriginal = ref(false);

const renderContent = computed(() => {
  if (renderOriginal.value) {
    return content.value;
  }

  if (hasTranslations.value) {
    return translationContent.value;
  }

  return content.value;
});

const isTemplate = computed(() => {
  return messageType.value === MESSAGE_TYPES.TEMPLATE;
});

const isEmpty = computed(() => {
  return !content.value && !attachments.value?.length;
});

const telegramForwardedFrom = computed(() => {
  return contentAttributes.value?.telegramForwardedFrom || null;
});

const telegramForwardedSource = computed(() => {
  const forwarded = telegramForwardedFrom.value;

  if (!forwarded) {
    return '';
  }

  if (forwarded.fromName) {
    return forwarded.fromName;
  }

  if (forwarded.postAuthor) {
    return forwarded.postAuthor;
  }

  if (forwarded.fromId?.type && forwarded.fromId?.id) {
    return `${forwarded.fromId.type} ${forwarded.fromId.id}`;
  }

  if (forwarded.savedFromPeer?.type && forwarded.savedFromPeer?.id) {
    return `${forwarded.savedFromPeer.type} ${forwarded.savedFromPeer.id}`;
  }

  return t('CONVERSATION.TELEGRAM.UNKNOWN_SOURCE');
});

const telegramReactionSummary = computed(() => {
  const results = contentAttributes.value?.telegramReactions?.results || [];

  return results.map(item => {
    const reaction = item?.reaction || {};

    if (reaction.emoji) {
      return `${reaction.emoji} ${item.count}`;
    }

    if (reaction.type === 'custom_emoji') {
      return `${t('CONVERSATION.TELEGRAM.CUSTOM_EMOJI')} ${item.count}`;
    }

    if (reaction.type === 'paid') {
      return `${t('CONVERSATION.TELEGRAM.PAID_REACTION')} ${item.count}`;
    }

    return `${t('CONVERSATION.TELEGRAM.REACTION')} ${item.count}`;
  });
});

const whatsappReactionSummary = computed(() => {
  const reactions = contentAttributes.value?.whatsappReactions || {};

  return Object.values(reactions)
    .map(reaction => reaction?.emoji)
    .filter(Boolean);
});

const handleSeeOriginal = () => {
  renderOriginal.value = !renderOriginal.value;
};
</script>

<template>
  <BaseBubble class="px-4 py-3" data-bubble-name="text">
    <div class="gap-3 flex flex-col">
      <div
        v-if="telegramForwardedFrom"
        class="text-xs text-n-slate-11 border-l-2 border-n-alpha-4 pl-2"
      >
        {{
          $t('CONVERSATION.TELEGRAM.FORWARDED_FROM', {
            source: telegramForwardedSource,
          })
        }}
      </div>
      <span v-if="isEmpty" class="text-n-slate-11">
        {{ $t('CONVERSATION.NO_CONTENT') }}
      </span>
      <FormattedContent v-if="renderContent" :content="renderContent" />
      <TranslationToggle
        v-if="hasTranslations"
        class="-mt-3"
        :showing-original="renderOriginal"
        @toggle="handleSeeOriginal"
      />
      <AttachmentChips :attachments="attachments" class="gap-2" />
      <template v-if="isTemplate">
        <div
          v-if="contentAttributes.submittedEmail"
          class="px-2 py-1 rounded-lg bg-n-alpha-3"
        >
          {{ contentAttributes.submittedEmail }}
        </div>
      </template>
      <div
        v-if="telegramReactionSummary.length"
        class="text-xs text-n-slate-11 flex flex-wrap items-center gap-1"
      >
        <span class="font-medium">
          {{ $t('CONVERSATION.TELEGRAM.REACTIONS') }}
        </span>
        <span>{{ telegramReactionSummary.join(' · ') }}</span>
      </div>
      <div
        v-if="whatsappReactionSummary.length"
        class="text-sm text-n-slate-11 flex flex-wrap items-center gap-1"
      >
        <span>{{ whatsappReactionSummary.join(' ') }}</span>
      </div>
      <CaptainToolExecutionGroup
        :additional-attributes="additionalAttributes"
      />
    </div>
  </BaseBubble>
</template>

<style>
p:last-child {
  margin-bottom: 0;
}
</style>
