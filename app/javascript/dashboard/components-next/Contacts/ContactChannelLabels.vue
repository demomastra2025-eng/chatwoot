<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { getInboxIconByType } from 'dashboard/helper/inbox';
import { copyTextToClipboard } from 'shared/helpers/clipboard';

const props = defineProps({
  contactInboxes: {
    type: Array,
    default: () => [],
  },
  existingConversationInboxIds: {
    type: Array,
    default: null,
  },
  title: {
    type: String,
    default: '',
  },
  copyOnClick: {
    type: Boolean,
    default: true,
  },
});

const emit = defineEmits(['select']);

const { t } = useI18n();

const channelName = (channelType, medium) => {
  if (medium === 'whatsapp' || /whatsapp/i.test(channelType)) return 'WhatsApp';
  if (/telegram/i.test(channelType)) return 'Telegram';
  if (/instagram/i.test(channelType)) return 'Instagram';
  if (/webwidget/i.test(channelType)) return t('CONTACT_PANEL.CHANNEL_WEB');
  if (/voice/i.test(channelType)) return t('CONTACT_PANEL.CHANNEL_CALLS');
  if (/email/i.test(channelType)) return 'Email';
  return t('CONTACT_PANEL.CHANNEL_OTHER');
};

const readableIdentifier = sourceId => {
  const value = String(sourceId || '').trim();
  return /^(\+?[\d\s()-]{7,}|@[\w.]+|[^\s@]+@[^\s@]+\.[^\s@]+)$/.test(value)
    ? value
    : '';
};

const existingConversationInboxIdSet = computed(() => {
  if (!Array.isArray(props.existingConversationInboxIds)) {
    return null;
  }

  return new Set(
    props.existingConversationInboxIds.map(inboxId => Number(inboxId))
  );
});

const channelLabels = computed(() => {
  return (props.contactInboxes || [])
    .map(contactInbox => {
      const inbox = contactInbox?.inbox || {};
      const inboxId = Number(inbox?.id || 0);
      const sourceId = contactInbox?.sourceId || contactInbox?.source_id || '';
      const channelType = inbox?.channelType || inbox?.channel_type || '';
      const medium = inbox?.medium || '';
      const willCreateNewConversation =
        !!existingConversationInboxIdSet.value &&
        !!inboxId &&
        !existingConversationInboxIdSet.value.has(inboxId);

      return {
        id: `${inbox?.id || channelType || 'channel'}-${sourceId}`,
        inboxId: inbox?.id || null,
        sourceId,
        inboxName: inbox?.name || '',
        label: [
          channelName(channelType, medium),
          inbox?.name || readableIdentifier(sourceId),
        ]
          .filter(Boolean)
          .join(' · '),
        icon: getInboxIconByType(channelType, medium, 'line'),
        willCreateNewConversation,
      };
    })
    .filter(channelLabel => channelLabel.inboxId || channelLabel.sourceId)
    .sort((left, right) => {
      if (left.willCreateNewConversation !== right.willCreateNewConversation) {
        return (
          Number(left.willCreateNewConversation) -
          Number(right.willCreateNewConversation)
        );
      }

      return `${left.inboxName}:${left.sourceId}`.localeCompare(
        `${right.inboxName}:${right.sourceId}`
      );
    });
});

const handleChannelIdentityClick = async channelLabel => {
  emit('select', channelLabel);
  if (!props.copyOnClick) return;

  await copyTextToClipboard(channelLabel.sourceId);
  useAlert(t('CONTACT_PANEL.COPY_SUCCESSFUL'));
};
</script>

<template>
  <div v-show="channelLabels.length" class="flex flex-col w-full gap-2">
    <span v-if="title" class="text-sm font-medium text-n-slate-10">
      {{ title }}
    </span>
    <div class="flex flex-wrap gap-2">
      <button
        v-for="channelLabel in channelLabels"
        :key="channelLabel.id"
        type="button"
        class="inline-flex max-w-full items-center gap-2 rounded-full border border-n-weak bg-n-slate-9/10 px-2.5 py-1 text-xs text-n-slate-12 shadow-sm transition-colors hover:border-n-slate-4 hover:bg-n-alpha-1"
        :class="channelLabel.willCreateNewConversation ? 'border-dashed' : ''"
        :title="channelLabel.label"
        @click="handleChannelIdentityClick(channelLabel)"
      >
        <span class="size-3.5 flex-shrink-0" :class="channelLabel.icon" />
        <span class="max-w-[14rem] truncate">
          {{ channelLabel.label }}
        </span>
      </button>
    </div>
  </div>
</template>
