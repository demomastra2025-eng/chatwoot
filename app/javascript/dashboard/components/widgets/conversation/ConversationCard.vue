<script setup>
import { computed, ref, watch, defineAsyncComponent } from 'vue';
import { useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { getLastMessage } from 'dashboard/helper/conversationHelper';
import {
  CONTENT_TYPES,
  MESSAGE_TYPES,
} from 'dashboard/components-next/message/constants';
import { frontendURL, conversationUrl } from 'dashboard/helper/URLHelper';
import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';
import { useI18n } from 'vue-i18n';
import Avatar from 'next/avatar/Avatar.vue';
import MessagePreview from './MessagePreview.vue';
import InboxName from '../InboxName.vue';
import TimeAgo from 'dashboard/components/ui/TimeAgo.vue';
import CardLabels from './conversationCardComponents/CardLabels.vue';
import CardPriorityIcon from 'dashboard/components-next/Conversation/ConversationCard/CardPriorityIcon.vue';
import SLACardLabel from './components/SLACardLabel.vue';
import ContextMenu from 'dashboard/components/ui/ContextMenu.vue';
import VoiceCallStatus from './VoiceCallStatus.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';

const props = defineProps({
  activeLabel: { type: String, default: '' },
  chat: { type: Object, default: () => ({}) },
  hideInboxName: { type: Boolean, default: false },
  hideThumbnail: { type: Boolean, default: false },
  teamId: { type: [String, Number], default: 0 },
  foldersId: { type: [String, Number], default: 0 },
  showAssignee: { type: Boolean, default: false },
  conversationType: { type: String, default: '' },
  activeStatus: { type: String, default: '' },
  activeAssigneeType: { type: String, default: '' },
  selected: { type: Boolean, default: false },
  selectable: { type: Boolean, default: true },
  compact: { type: Boolean, default: false },
  enableContextMenu: { type: Boolean, default: false },
  allowedContextMenuOptions: { type: Array, default: () => [] },
  communicationThreadMode: { type: Boolean, default: false },
});

const emit = defineEmits([
  'contextMenuToggle',
  'assignAgent',
  'assignLabel',
  'removeLabel',
  'assignTeam',
  'markAsUnread',
  'markAsRead',
  'assignPriority',
  'updateConversationStatus',
  'deleteConversation',
  'selectConversation',
  'deSelectConversation',
]);

const ConversationContextMenu = defineAsyncComponent(
  () => import('./contextMenu/Index.vue')
);

const router = useRouter();
const store = useStore();
const { t } = useI18n();

const hovered = ref(false);
const showContextMenu = ref(false);
const contextMenu = ref({ x: null, y: null });
const isUpdatingPin = ref(false);
const INLINE_META_MAX_LENGTH = 12;

// Reset UI state when conversation changes at same index (no :key, instance reused on reorder)
// This prevents context menu/hover state from leaking to a different conversation
// Emit contextMenuToggle(false) to sync parent state if menu was open during recycling
const resetState = () => {
  if (showContextMenu.value) {
    emit('contextMenuToggle', false);
  }
  hovered.value = false;
  showContextMenu.value = false;
  contextMenu.value = { x: null, y: null };
};

watch(() => props.chat.id, resetState);

const currentChat = useMapGetter('getSelectedChat');
const inboxesList = useMapGetter('inboxes/getInboxes');
const activeInbox = useMapGetter('getSelectedInbox');
const accountId = useMapGetter('getCurrentAccountId');

const chatMetadata = computed(() => props.chat.meta || {});
const isCommunicationThreadChat = computed(() =>
  isCommunicationThread(props.chat)
);

const assignee = computed(() => chatMetadata.value.assignee || {});

const senderId = computed(() => chatMetadata.value.sender?.id);

const currentContact = computed(() => {
  return senderId.value
    ? store.getters['contacts/getContact'](senderId.value)
    : {};
});

const truncateInlineMetaText = value => {
  const text = String(value || '').trim();
  return text.length > INLINE_META_MAX_LENGTH
    ? `${text.slice(0, INLINE_META_MAX_LENGTH)}…`
    : text;
};

const contactDisplayName = computed(() =>
  truncateInlineMetaText(currentContact.value.name)
);

const cardMatchesListMode = computed(
  () =>
    Boolean(props.communicationThreadMode) === isCommunicationThreadChat.value
);

const isActiveChat = computed(() => {
  return (
    cardMatchesListMode.value &&
    String(currentChat.value?.id) === String(props.chat.id) &&
    isCommunicationThread(currentChat.value) === isCommunicationThreadChat.value
  );
});

const unreadCount = computed(() => props.chat.unread_count);

const hasUnread = computed(() => unreadCount.value > 0);

const unreadBadgeLabel = computed(() => {
  return unreadCount.value > 99 ? '99+' : `${unreadCount.value}`;
});

const unreadBadgeClass = computed(() => {
  return unreadBadgeLabel.value.length > 2 ? 'h-5 min-w-5 px-1.5' : 'size-5';
});

const lastMessageInChat = computed(() => getLastMessage(props.chat));

const lastMessageType = computed(
  () =>
    lastMessageInChat.value?.message_type ??
    lastMessageInChat.value?.messageType
);

const isLastMessageActivity = computed(
  () => Number(lastMessageType.value) === MESSAGE_TYPES.ACTIVITY
);

const isVoiceCallMessage = message => {
  return (
    message?.content_type === CONTENT_TYPES.VOICE_CALL ||
    message?.contentType === CONTENT_TYPES.VOICE_CALL
  );
};

const callDirectionFromMessageType = messageType => {
  if (Number(messageType) === MESSAGE_TYPES.OUTGOING) {
    return 'outbound';
  }
  if (Number(messageType) === MESSAGE_TYPES.INCOMING) {
    return 'inbound';
  }
  return '';
};

const voiceCallDataFromLastMessage = computed(() => {
  const lastMessage = lastMessageInChat.value;
  if (!isVoiceCallMessage(lastMessage)) return { status: '', direction: '' };

  const contentAttributes =
    lastMessage.content_attributes || lastMessage.contentAttributes || {};
  const data = contentAttributes.data || {};
  const messageType = lastMessage.message_type ?? lastMessage.messageType;

  return {
    status: data.status,
    direction:
      data.call_direction ||
      data.callDirection ||
      callDirectionFromMessageType(messageType),
  };
});

const voiceCallData = computed(() => {
  const additionalAttributes = props.chat.additional_attributes || {};
  if (additionalAttributes.call_status) {
    return {
      status: additionalAttributes.call_status,
      direction: additionalAttributes.call_direction,
    };
  }

  return voiceCallDataFromLastMessage.value;
});

const inboxId = computed(() => props.chat.inbox_id);

const fallbackInboxId = computed(() => {
  if (activeInbox.value) return activeInbox.value;
  if (
    props.activeLabel ||
    props.teamId ||
    props.foldersId ||
    props.conversationType
  ) {
    return null;
  }
  return inboxId.value;
});

const inbox = computed(() => {
  return inboxId.value ? store.getters['inboxes/getInbox'](inboxId.value) : {};
});

const selectionInboxIds = computed(() => {
  if (isCommunicationThreadChat.value) {
    return [
      ...new Set(
        (props.chat.channels || [])
          .map(channel => channel.inbox_id)
          .filter(Boolean)
      ),
    ];
  }

  return inbox.value.id ? [inbox.value.id] : [];
});

const showInboxName = computed(() => {
  return !props.hideInboxName && inboxesList.value.length > 1;
});

const lastEventIconClass = computed(() => {
  if (Number(lastMessageType.value) === MESSAGE_TYPES.OUTGOING) {
    return 'i-lucide-arrow-left';
  }
  if (Number(lastMessageType.value) === MESSAGE_TYPES.INCOMING) {
    return 'i-lucide-arrow-right';
  }
  if (isLastMessageActivity.value) {
    return 'i-lucide-info';
  }
  return '';
});

const hasSlaPolicyId = computed(() => props.chat?.sla_policy_id);

const showLabelsSection = computed(() => {
  return props.chat.labels?.length > 0 || hasSlaPolicyId.value;
});

const messagePreviewClass = computed(() => {
  return [
    isLastMessageActivity.value || !lastMessageInChat.value
      ? 'text-n-slate-11'
      : 'text-n-slate-12',
    hasUnread.value ? 'font-medium' : '',
    !props.compact && hasUnread.value ? 'ltr:pr-4 rtl:pl-4' : '',
    props.compact && hasUnread.value ? 'ltr:pr-6 rtl:pl-6' : '',
  ];
});

const showPreviewMessageType = computed(() => !isLastMessageActivity.value);

const isPinned = computed(() => Boolean(props.chat?.custom_attributes?.pinned));

const conversationPath = computed(() => {
  return frontendURL(
    conversationUrl({
      accountId: accountId.value,
      activeInbox: fallbackInboxId.value,
      id: props.chat.id,
      label: props.activeLabel,
      teamId: props.teamId,
      conversationType: props.conversationType,
      foldersId: props.foldersId,
      status: props.activeStatus,
      assigneeType: props.activeAssigneeType,
      communicationThread: isCommunicationThreadChat.value,
    })
  );
});

const onCardClick = e => {
  const path = conversationPath.value;
  if (!path) return;

  // Handle Ctrl/Cmd + Click for new tab
  if (e.metaKey || e.ctrlKey) {
    e.preventDefault();
    window.open(
      `${window.chatwootConfig.hostURL}${path}`,
      '_blank',
      'noopener,noreferrer'
    );
    return;
  }

  // Skip if already active
  if (isActiveChat.value) return;

  router.push(path);
};

const onThumbnailHover = () => {
  hovered.value = !props.hideThumbnail;
};

const onThumbnailLeave = () => {
  hovered.value = false;
};

const onSelectConversation = checked => {
  if (checked) {
    emit('selectConversation', props.chat.id, selectionInboxIds.value);
  } else {
    emit('deSelectConversation', props.chat.id, selectionInboxIds.value);
  }
};

const openContextMenu = e => {
  if (!props.enableContextMenu) return;
  e.preventDefault();
  emit('contextMenuToggle', true);
  contextMenu.value.x = e.pageX || e.clientX;
  contextMenu.value.y = e.pageY || e.clientY;
  showContextMenu.value = true;
};

const closeContextMenu = () => {
  emit('contextMenuToggle', false);
  showContextMenu.value = false;
  contextMenu.value.x = null;
  contextMenu.value.y = null;
};

const onUpdateConversation = (status, snoozedUntil) => {
  closeContextMenu();
  emit('updateConversationStatus', props.chat.id, status, snoozedUntil);
};

const onAssignAgent = agent => {
  emit('assignAgent', agent, [props.chat.id]);
  closeContextMenu();
};

const onAssignLabel = label => {
  emit('assignLabel', [label.title], [props.chat.id]);
};

const onRemoveLabel = label => {
  emit('removeLabel', [label.title], [props.chat.id]);
};

const onAssignTeam = team => {
  emit('assignTeam', team, props.chat.id);
  closeContextMenu();
};

const markAsUnread = () => {
  emit('markAsUnread', props.chat.id);
  closeContextMenu();
};

const markAsRead = () => {
  emit('markAsRead', props.chat.id);
  closeContextMenu();
};

const assignPriority = priority => {
  emit('assignPriority', priority, props.chat.id);
  closeContextMenu();
};

const deleteConversation = () => {
  emit('deleteConversation', props.chat.id);
  closeContextMenu();
};

const togglePinnedConversation = async nextPinnedState => {
  if (isUpdatingPin.value) {
    return;
  }

  isUpdatingPin.value = true;

  try {
    await store.dispatch('setConversationPinned', {
      conversationId: props.chat.id,
      pinned: nextPinnedState,
    });
  } catch (error) {
    useAlert(t('CONVERSATION.CARD_CONTEXT_MENU.PIN_UPDATE_ERROR'));
  } finally {
    isUpdatingPin.value = false;
    closeContextMenu();
  }
};
</script>

<template>
  <div
    class="relative flex items-start flex-grow-0 flex-shrink-0 w-auto max-w-full py-0 border-t-0 border-b-0 border-l-0 border-r-0 border-transparent border-solid cursor-pointer conversation hover:bg-n-alpha-1 dark:hover:bg-n-alpha-3 group"
    :class="{
      'active animate-card-select bg-n-background border-n-weak': isActiveChat,
      'bg-n-slate-2': selected,
      'px-0': compact,
      'px-2': !compact,
    }"
    @click="onCardClick"
    @contextmenu="openContextMenu($event)"
  >
    <div
      class="relative flex w-10 flex-shrink-0 flex-col items-center"
      @mouseenter="onThumbnailHover"
      @mouseleave="onThumbnailLeave"
    >
      <Avatar
        v-if="!hideThumbnail"
        :name="currentContact.name"
        :src="currentContact.thumbnail"
        :size="28"
        :status="currentContact.availability_status"
        class="mt-3"
        hide-offline-status
        rounded-full
      >
        <template #overlay="{ size }">
          <label
            v-if="selectable && (hovered || selected)"
            class="flex items-center justify-center rounded-full cursor-pointer absolute inset-0 z-10 backdrop-blur-[2px]"
            :style="{ width: `${size}px`, height: `${size}px` }"
            @click.stop
          >
            <Checkbox
              :model-value="selected"
              class="!m-0 cursor-pointer"
              @change="onSelectConversation($event.target.checked)"
            />
          </label>
        </template>
      </Avatar>
      <TimeAgo
        v-if="!hideThumbnail"
        display-mode="compact_elapsed"
        class="mt-1 max-w-10"
        :last-activity-timestamp="chat.timestamp"
        :created-at-timestamp="chat.created_at"
        :conversation-id="chat.id"
      />
    </div>
    <div
      class="px-0 py-2 border-b group-hover:border-transparent flex-1 border-n-slate-3 min-w-0"
    >
      <h4
        class="conversation--user text-xs my-0 mx-2 pt-0.5 overflow-hidden whitespace-nowrap flex items-center gap-1 flex-1 min-w-0 text-n-slate-12"
      >
        <span
          class="min-w-0 truncate capitalize"
          :class="hasUnread ? 'font-semibold' : 'font-medium'"
        >
          {{ contactDisplayName }}
        </span>
        <i
          v-if="lastEventIconClass"
          class="size-3 flex-shrink-0 text-n-slate-10"
          :class="lastEventIconClass"
        />
        <InboxName
          v-if="showInboxName"
          :inbox="inbox"
          compact
          :max-length="INLINE_META_MAX_LENGTH"
          class="max-w-20 flex-shrink min-w-0"
        />
        <span
          v-if="showAssignee && assignee.name"
          class="ml-auto inline-flex min-w-0 flex-1 items-center justify-end gap-0.5 text-xxs font-medium normal-case leading-3 text-n-slate-11"
        >
          <fluent-icon
            icon="person"
            size="10"
            class="flex-shrink-0 text-n-slate-11"
          />
          <span class="min-w-0 truncate">
            {{ assignee.name }}
          </span>
        </span>
        <CardPriorityIcon
          v-if="chat.priority"
          :priority="chat.priority"
          class="ml-0.5 flex-shrink-0 !size-3"
        />
        <span
          v-if="isPinned"
          class="inline-flex items-center gap-1 rounded-md border border-n-slate-4 bg-n-slate-3 px-2 py-0.5 text-[11px] font-medium leading-4 text-n-slate-12 dark:border-n-slate-6 dark:bg-n-slate-2"
        >
          <i class="i-lucide-pin size-3 text-n-slate-11" />
          {{ t('CONVERSATION.CARD_CONTEXT_MENU.PINNED_BADGE') }}
        </span>
      </h4>
      <div
        v-if="voiceCallData.status"
        key="voice-status-row"
        class="flex min-w-0 flex-1 items-center gap-1"
      >
        <VoiceCallStatus
          :status="voiceCallData.status"
          :direction="voiceCallData.direction"
          :message-preview-class="messagePreviewClass"
        />
        <span
          v-if="hasUnread"
          class="inline-flex flex-shrink-0 items-center justify-center rounded-full bg-n-brand-solid text-center text-[11px] font-semibold leading-none text-n-brand-contrast shadow-lg ltr:mr-2 rtl:ml-2"
          :class="unreadBadgeClass"
        >
          {{ unreadBadgeLabel }}
        </span>
      </div>
      <div v-else class="mx-2 flex h-6 min-w-0 flex-1 items-center gap-1">
        <MessagePreview
          v-if="lastMessageInChat"
          key="message-preview"
          :message="lastMessageInChat"
          :show-message-type="showPreviewMessageType"
          class="my-0 leading-6 min-w-0 flex-1 text-xs"
          :class="messagePreviewClass"
        />
        <p
          v-else
          key="no-messages"
          class="text-n-slate-11 text-xs my-0 leading-6 min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap"
          :class="messagePreviewClass"
        >
          <fluent-icon
            size="14"
            class="-mt-0.5 align-middle inline-block text-n-slate-10"
            icon="info"
          />
          <span class="mx-0.5">
            {{ $t(`CHAT_LIST.NO_MESSAGES`) }}
          </span>
        </p>
        <span
          v-if="hasUnread"
          class="inline-flex flex-shrink-0 items-center justify-center rounded-full bg-n-brand-solid text-center text-[11px] font-semibold leading-none text-n-brand-contrast shadow-lg"
          :class="unreadBadgeClass"
        >
          {{ unreadBadgeLabel }}
        </span>
      </div>
      <CardLabels
        v-if="showLabelsSection"
        :conversation-labels="chat.labels"
        class="mt-0.5 mx-2 mb-0"
      >
        <template v-if="hasSlaPolicyId" #before>
          <SLACardLabel :chat="chat" class="ltr:mr-1 rtl:ml-1" />
        </template>
      </CardLabels>
    </div>
    <ContextMenu
      v-if="showContextMenu"
      :x="contextMenu.x"
      :y="contextMenu.y"
      @close="closeContextMenu"
    >
      <ConversationContextMenu
        :status="chat.status"
        :inbox-id="inbox.id"
        :priority="chat.priority"
        :chat-id="chat.id"
        :has-unread-messages="hasUnread"
        :conversation-labels="chat.labels"
        :conversation-url="conversationPath"
        :allowed-options="allowedContextMenuOptions"
        :is-pinned="isPinned"
        @update-conversation="onUpdateConversation"
        @assign-agent="onAssignAgent"
        @assign-label="onAssignLabel"
        @remove-label="onRemoveLabel"
        @assign-team="onAssignTeam"
        @mark-as-unread="markAsUnread"
        @mark-as-read="markAsRead"
        @assign-priority="assignPriority"
        @delete-conversation="deleteConversation"
        @toggle-pin="togglePinnedConversation"
        @close="closeContextMenu"
      />
    </ContextMenu>
  </div>
</template>
