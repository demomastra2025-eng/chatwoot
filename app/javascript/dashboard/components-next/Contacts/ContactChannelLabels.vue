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
        icon: getInboxIconByType(channelType, medium, 'line'),
        willCreateNewConversation,
      };
    })
    .filter(channelLabel => channelLabel.sourceId)
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
        :title="
          channelLabel.inboxName
            ? `${channelLabel.inboxName}: ${channelLabel.sourceId}`
            : channelLabel.sourceId
        "
        @click="handleChannelIdentityClick(channelLabel)"
      >
        <span
          v-if="channelLabel.willCreateNewConversation"
          data-testid="new-conversation-indicator"
          class="inline-flex h-4 w-4 shrink-0 items-center justify-center rounded-full border border-n-weak bg-n-alpha-1 text-[10px] font-semibold text-n-slate-12"
          :title="t('CONTACT_PANEL.NO_CHANNEL_CONVERSATION')"
        >
          <span class="i-lucide-plus size-2.5" />
        </span>
        <span class="size-3.5 flex-shrink-0" :class="channelLabel.icon" />
        <span class="max-w-[14rem] truncate">
          {{ channelLabel.sourceId }}
        </span>
      </button>
    </div>
  </div>
</template>
