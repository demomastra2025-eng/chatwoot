<script setup>
import { computed, ref } from 'vue';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const props = defineProps({
  threadId: {
    type: [String, Number],
    default: null,
  },
  channels: {
    type: Array,
    default: () => [],
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['confirm', 'close']);

const dialogRef = ref(null);
const selectedConversationIds = ref([]);

const selectedCount = computed(() => selectedConversationIds.value.length);
const hasSelection = computed(() => selectedCount.value > 0);
const deletableChannels = computed(() =>
  props.channels
    .map(channel => ({
      ...(channel || {}),
      conversation_id: Number(channel?.conversation_id),
    }))
    .filter(
      channel =>
        Number.isInteger(channel.conversation_id) && channel.conversation_id > 0
    )
);
const allChannelsSelected = computed(
  () =>
    deletableChannels.value.length > 0 &&
    selectedCount.value === deletableChannels.value.length
);

const channelType = channel =>
  channel.medium || channel.provider || channel.channel || 'Channel';

const channelIdentifier = channel =>
  channel.source_id ||
  channel.channel_profile?.name ||
  channel.channel_key ||
  channel.contact_inbox_id ||
  channel.conversation_id;

const channelTitle = channel =>
  [channel.inbox_name, channelType(channel)].filter(Boolean).join(' · ');

const resetSelection = () => {
  selectedConversationIds.value = [];
};

const open = () => {
  resetSelection();
  dialogRef.value?.open();
};

const close = () => {
  resetSelection();
  dialogRef.value?.close();
};

const handleClose = () => {
  resetSelection();
  emit('close');
};

const confirm = () => {
  if (!hasSelection.value || props.isLoading) return;

  emit('confirm', [...selectedConversationIds.value]);
};

const toggleAll = event => {
  selectedConversationIds.value = event.target.checked
    ? deletableChannels.value.map(channel => channel.conversation_id)
    : [];
};

defineExpose({ open, close });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="alert"
    width="xl"
    :title="
      $t('CONVERSATION.DELETE_COMMUNICATION_THREAD_CHANNELS.TITLE', {
        threadId,
      })
    "
    :confirm-button-label="
      $t('CONVERSATION.DELETE_COMMUNICATION_THREAD_CHANNELS.CONFIRM')
    "
    :disable-confirm-button="!hasSelection"
    :is-loading="isLoading"
    @confirm="confirm"
    @close="handleClose"
  >
    <template #description>
      <p class="mb-0 text-sm text-n-slate-11">
        {{
          $t('CONVERSATION.DELETE_COMMUNICATION_THREAD_CHANNELS.DESCRIPTION')
        }}
      </p>
    </template>

    <div class="flex flex-col gap-3">
      <label
        v-if="deletableChannels.length > 1"
        class="flex items-center gap-3 rounded-lg border border-n-weak px-3 py-2 text-sm text-n-slate-12"
      >
        <input
          type="checkbox"
          class="h-4 w-4 rounded border-n-strong"
          :checked="allChannelsSelected"
          @change="toggleAll"
        />
        <span>
          {{
            $t('CONVERSATION.DELETE_COMMUNICATION_THREAD_CHANNELS.SELECT_ALL')
          }}
        </span>
      </label>

      <p v-if="!deletableChannels.length" class="mb-0 text-sm text-n-slate-11">
        {{ $t('CONVERSATION.DELETE_COMMUNICATION_THREAD_CHANNELS.EMPTY') }}
      </p>

      <label
        v-for="channel in deletableChannels"
        :key="channel.conversation_id"
        class="flex cursor-pointer items-start gap-3 rounded-lg border border-n-weak px-3 py-2 hover:bg-n-alpha-1"
      >
        <input
          v-model="selectedConversationIds"
          type="checkbox"
          class="mt-1 h-4 w-4 rounded border-n-strong"
          :value="channel.conversation_id"
          :data-test-id="`delete-channel-${channel.conversation_id}`"
        />
        <span class="min-w-0 flex-1">
          <span class="block truncate text-sm font-medium text-n-slate-12">
            {{ channelTitle(channel) }}
          </span>
          <span class="block truncate text-xs text-n-slate-11">
            {{
              [
                channelIdentifier(channel),
                $t(
                  'CONVERSATION.DELETE_COMMUNICATION_THREAD_CHANNELS.CHANNEL_ID',
                  {
                    conversationId: channel.conversation_id,
                  }
                ),
              ].join(' · ')
            }}
          </span>
        </span>
      </label>

      <p v-if="allChannelsSelected" class="mb-0 text-xs text-n-ruby-11">
        {{
          $t(
            'CONVERSATION.DELETE_COMMUNICATION_THREAD_CHANNELS.ALL_SELECTED_WARNING'
          )
        }}
      </p>
    </div>
  </Dialog>
</template>
