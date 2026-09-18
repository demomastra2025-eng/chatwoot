<script setup>
import { computed, ref, watch, defineAsyncComponent, onUnmounted } from 'vue';
import { useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { getLastMessage } from 'dashboard/helper/conversationHelper';
import {
  CONTENT_TYPES,
  MESSAGE_STATUS,
  MESSAGE_TYPES,
} from 'dashboard/components-next/message/constants';
import { frontendURL, conversationUrl } from 'dashboard/helper/URLHelper';
import { rememberConversationListReturnPath } from 'dashboard/helper/conversationListReturnContext';
import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';
import { useI18n } from 'vue-i18n';
import Avatar from 'next/avatar/Avatar.vue';
import ChannelIcon from 'dashboard/components-next/icon/ChannelIcon.vue';
import MessageStatus from 'dashboard/components-next/message/MessageStatus.vue';
import MessagePreview from './MessagePreview.vue';

import CardLabels from './conversationCardComponents/CardLabels.vue';
import CardPriorityIcon from 'dashboard/components-next/Conversation/ConversationCard/CardPriorityIcon.vue';
import SLACardLabel from './components/SLACardLabel.vue';
import ContextMenu from 'dashboard/components/ui/ContextMenu.vue';
import VoiceCallStatus from './VoiceCallStatus.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import {
  APPOINTMENT_STATUS_ICON_CLASSES,
  APPOINTMENT_STATUS_ICONS,
  APPOINTMENT_STATUS_STICKER_CLASSES,
} from 'dashboard/routes/dashboard/scheduling/constants';

const props = defineProps({
  activeLabel: { type: String, default: '' },
  chat: { type: Object, default: () => ({}) },
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
const { t, locale } = useI18n();
const currentLocale = computed(() => locale?.value || 'en');

const hovered = ref(false);
const showContextMenu = ref(false);
const contextMenu = ref({ x: null, y: null });
const isUpdatingPin = ref(false);
const isTouchContextMenu = ref(false);
const longPressTimer = ref(null);
const suppressNextClick = ref(false);
const suppressClickResetTimer = ref(null);
const touchStartPoint = ref(null);
const INLINE_META_MAX_LENGTH = 12;
const LONG_PRESS_MS = 550;
const LONG_PRESS_MOVE_TOLERANCE = 10;

const clearLongPressTimer = () => {
  if (!longPressTimer.value) return;

  window.clearTimeout(longPressTimer.value);
  longPressTimer.value = null;
};

const clearSuppressClickResetTimer = () => {
  if (!suppressClickResetTimer.value) return;

  window.clearTimeout(suppressClickResetTimer.value);
  suppressClickResetTimer.value = null;
};

const scheduleSuppressClickReset = () => {
  clearSuppressClickResetTimer();
  suppressClickResetTimer.value = window.setTimeout(() => {
    suppressNextClick.value = false;
    suppressClickResetTimer.value = null;
  }, 350);
};

// Reset UI state when conversation changes at same index (no :key, instance reused on reorder)
// This prevents context menu/hover state from leaking to a different conversation
// Emit contextMenuToggle(false) to sync parent state if menu was open during recycling
const resetState = () => {
  clearLongPressTimer();
  clearSuppressClickResetTimer();
  if (showContextMenu.value) {
    emit('contextMenuToggle', false);
  }
  hovered.value = false;
  showContextMenu.value = false;
  isTouchContextMenu.value = false;
  suppressNextClick.value = false;
  touchStartPoint.value = null;
  contextMenu.value = { x: null, y: null };
};

watch(() => props.chat.id, resetState);

onUnmounted(resetState);

const currentChat = useMapGetter('getSelectedChat');
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
    ? store.getters['contacts/getContact'](senderId.value) || {}
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

const schedulingAppointmentStatuses = computed(() => {
  const statuses =
    props.chat.scheduling_appointment_statuses ||
    props.chat.schedulingAppointmentStatuses ||
    [];
  return Array.isArray(statuses)
    ? statuses
        .map(statusContext => ({
          count: Number(statusContext.count || 0),
          status: String(statusContext.status || statusContext).trim(),
        }))
        .filter(statusContext => statusContext.status)
    : [];
});

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

const outgoingMessageStatus = computed(() => {
  if (Number(lastMessageType.value) !== MESSAGE_TYPES.OUTGOING) return '';

  const status = lastMessageInChat.value?.status;
  return [
    MESSAGE_STATUS.PROGRESS,
    MESSAGE_STATUS.SENT,
    MESSAGE_STATUS.DELIVERED,
    MESSAGE_STATUS.READ,
  ].includes(status)
    ? status
    : '';
});

const lastMessageTimestamp = computed(() =>
  Number(
    lastMessageInChat.value?.created_at ??
      lastMessageInChat.value?.createdAt ??
      0
  )
);

const lastMessageTimeLabel = computed(() => {
  if (!lastMessageTimestamp.value) return '';
  const date = new Date(lastMessageTimestamp.value * 1000);
  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const dateStart = new Date(
    date.getFullYear(),
    date.getMonth(),
    date.getDate()
  );
  const dayDifference = Math.round((todayStart - dateStart) / 86400000);

  if (dayDifference === 0) {
    return new Intl.DateTimeFormat(currentLocale.value, {
      hour: '2-digit',
      minute: '2-digit',
    }).format(date);
  }
  if (dayDifference === 1) {
    return t('CONVERSATION.DATE_DIVIDER.YESTERDAY');
  }
  if (date.getFullYear() === now.getFullYear()) {
    return new Intl.DateTimeFormat(currentLocale.value, {
      day: 'numeric',
      month: 'short',
    }).format(date);
  }

  return new Intl.DateTimeFormat(currentLocale.value, {
    day: '2-digit',
    month: '2-digit',
    year: '2-digit',
  }).format(date);
});

const appointmentStatusLabels = computed(() => ({
  cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
  completed: t('SCHEDULING.APPOINTMENT_STATUS.completed'),
  confirmed: t('SCHEDULING.APPOINTMENT_STATUS.confirmed'),
  no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
  scheduled: t('SCHEDULING.APPOINTMENT_STATUS.scheduled'),
}));

const appointmentStatusTitle = statusContext => {
  const label =
    appointmentStatusLabels.value[statusContext.status] || statusContext.status;
  return statusContext.count > 1 ? `${label} · ${statusContext.count}` : label;
};

const primaryAppointmentStatus = computed(
  () => schedulingAppointmentStatuses.value[0] || null
);

const appointmentStatusStickerIcon = computed(
  () =>
    APPOINTMENT_STATUS_ICONS[primaryAppointmentStatus.value?.status] ||
    APPOINTMENT_STATUS_ICONS.scheduled
);

const appointmentStatusStickerIconClass = computed(
  () =>
    APPOINTMENT_STATUS_ICON_CLASSES[primaryAppointmentStatus.value?.status] ||
    'text-n-slate-11'
);

const appointmentStatusStickerClass = computed(() => {
  const status = primaryAppointmentStatus.value?.status;
  return (
    APPOINTMENT_STATUS_STICKER_CLASSES[status] ||
    'border-n-slate-4 bg-n-slate-2 text-n-slate-11 dark:border-n-slate-6 dark:bg-n-slate-3'
  );
});

const appointmentStatusStickerTitle = computed(() =>
  schedulingAppointmentStatuses.value.map(appointmentStatusTitle).join(' / ')
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

const hasSlaPolicyId = computed(() => props.chat?.sla_policy_id);

const showLabelsSection = computed(() => {
  return props.chat.labels?.length > 0 || hasSlaPolicyId.value;
});

const messagePreviewClass = computed(() => {
  return [
    lastMessageInChat.value ? 'text-n-slate-12' : 'text-n-slate-11',
    hasUnread.value ? 'font-semibold' : '',
    !props.compact && hasUnread.value ? 'ltr:pr-4 rtl:pl-4' : '',
    props.compact && hasUnread.value ? 'ltr:pr-6 rtl:pl-6' : '',
  ];
});

const showPreviewMessageType = computed(() => Boolean(lastMessageInChat.value));

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
  if (suppressNextClick.value) {
    e.preventDefault();
    e.stopPropagation();
    suppressNextClick.value = false;
    return;
  }

  const path = conversationPath.value;
  if (!path) return;
  const navigationState = isCommunicationThreadChat.value
    ? rememberConversationListReturnPath({
        accountId: accountId.value,
        threadId: props.chat.id,
        path: `${window.location.pathname}${window.location.search}`,
      })
    : {};

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

  router.push(
    isCommunicationThreadChat.value ? { path, state: navigationState } : path
  );
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

const isInteractiveTarget = target =>
  Boolean(
    target?.closest?.(
      'a, button, input, select, textarea, label, [role="button"], [data-skip-long-press]'
    )
  );

const openContextMenuAt = ({ x, y, touch = false }) => {
  if (!props.enableContextMenu) return;

  emit('contextMenuToggle', true);
  contextMenu.value.x = x;
  contextMenu.value.y = y;
  isTouchContextMenu.value = touch;
  showContextMenu.value = true;
};

const openContextMenu = e => {
  if (!props.enableContextMenu) return;

  e.preventDefault();
  const touchTriggeredContextMenu = Boolean(
    isTouchContextMenu.value ||
      e.pointerType === 'touch' ||
      e.sourceCapabilities?.firesTouchEvents
  );
  openContextMenuAt({
    x: e.clientX ?? e.pageX ?? 0,
    y: e.clientY ?? e.pageY ?? 0,
    touch: touchTriggeredContextMenu,
  });
};

const onTouchStart = event => {
  if (
    !props.enableContextMenu ||
    event.touches.length !== 1 ||
    isInteractiveTarget(event.target)
  ) {
    return;
  }

  const touch = event.touches[0];
  touchStartPoint.value = {
    x: touch.clientX,
    y: touch.clientY,
  };
  clearLongPressTimer();
  longPressTimer.value = window.setTimeout(() => {
    suppressNextClick.value = true;
    openContextMenuAt({ x: touch.clientX, y: touch.clientY, touch: true });
  }, LONG_PRESS_MS);
};

const onTouchMove = event => {
  if (!touchStartPoint.value || event.touches.length !== 1) return;

  const touch = event.touches[0];
  const deltaX = Math.abs(touch.clientX - touchStartPoint.value.x);
  const deltaY = Math.abs(touch.clientY - touchStartPoint.value.y);

  if (
    deltaX > LONG_PRESS_MOVE_TOLERANCE ||
    deltaY > LONG_PRESS_MOVE_TOLERANCE
  ) {
    clearLongPressTimer();
  }
};

const onTouchEnd = event => {
  clearLongPressTimer();
  touchStartPoint.value = null;

  if (suppressNextClick.value) {
    event.preventDefault();
    scheduleSuppressClickReset();
  }
};

const onTouchCancel = () => {
  clearLongPressTimer();
  touchStartPoint.value = null;
};

const closeContextMenu = () => {
  emit('contextMenuToggle', false);
  showContextMenu.value = false;
  isTouchContextMenu.value = false;
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
      conversationType: isCommunicationThreadChat.value
        ? 'communication_thread'
        : 'conversation',
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
    @touchstart="onTouchStart"
    @touchmove="onTouchMove"
    @touchend="onTouchEnd"
    @touchcancel="onTouchCancel"
  >
    <div
      class="relative flex w-10 flex-shrink-0 flex-col items-center"
      @mouseenter="onThumbnailHover"
      @mouseleave="onThumbnailLeave"
    >
      <Avatar
        v-if="!hideThumbnail"
        :name="contactDisplayName"
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
      <span
        v-if="!hideThumbnail && lastMessageTimeLabel"
        data-test-id="conversation-card-last-message-time"
        class="mt-1 max-w-10 truncate text-center text-[9px] font-normal leading-3 tabular-nums text-n-slate-10"
      >
        {{ lastMessageTimeLabel }}
      </span>
      <span
        v-if="!hideThumbnail && primaryAppointmentStatus"
        data-test-id="conversation-appointment-status-sticker"
        class="absolute right-0 top-2 z-20 inline-flex size-4 items-center justify-center rounded-full border shadow-sm"
        :class="appointmentStatusStickerClass"
        :title="appointmentStatusStickerTitle"
      >
        <i
          class="size-2.5"
          :class="[
            appointmentStatusStickerIcon,
            appointmentStatusStickerIconClass,
          ]"
          aria-hidden="true"
        />
        <span class="sr-only">{{ appointmentStatusStickerTitle }}</span>
      </span>
    </div>
    <div class="min-w-0 flex-1 px-0 py-2">
      <h4
        class="conversation--user text-xs my-0 mx-2 pt-0.5 overflow-hidden whitespace-nowrap flex items-center gap-1 flex-1 min-w-0 text-n-slate-12"
      >
        <span
          class="min-w-0 truncate capitalize"
          :class="hasUnread ? 'font-semibold' : 'font-medium'"
        >
          {{ contactDisplayName }}
        </span>
        <ChannelIcon
          :inbox="inbox"
          fallback-icon="i-lucide-circle-question-mark"
          fallback-icon-class="!size-2.5"
          data-test-id="conversation-channel-icon"
          class="size-3 flex-shrink-0 text-n-slate-11"
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
        <MessageStatus
          v-if="outgoingMessageStatus"
          data-test-id="conversation-message-status"
          :status="outgoingMessageStatus"
          class="shrink-0"
          :class="
            outgoingMessageStatus === MESSAGE_STATUS.PROGRESS
              ? '!size-2.5'
              : '!size-3'
          "
        />
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
        <MessageStatus
          v-if="outgoingMessageStatus"
          data-test-id="conversation-message-status"
          :status="outgoingMessageStatus"
          class="shrink-0"
          :class="
            outgoingMessageStatus === MESSAGE_STATUS.PROGRESS
              ? '!size-2.5'
              : '!size-3'
          "
        />
        <MessagePreview
          v-if="lastMessageInChat"
          key="message-preview"
          :message="lastMessageInChat"
          :show-message-type="showPreviewMessageType"
          :show-direction-icon="false"
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
    <span
      data-test-id="conversation-card-separator"
      class="absolute bottom-0 left-3 right-3 h-px bg-n-slate-3 group-hover:bg-transparent"
      aria-hidden="true"
    />
    <ContextMenu
      v-if="showContextMenu"
      :x="contextMenu.x"
      :y="contextMenu.y"
      :mobile="isTouchContextMenu"
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
        :mobile="isTouchContextMenu"
        :conversation-type="
          isCommunicationThreadChat ? 'communication_thread' : 'conversation'
        "
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
