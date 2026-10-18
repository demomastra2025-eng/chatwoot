<script setup>
import { onMounted, computed, ref, toRefs } from 'vue';
import { useTimeoutFn } from '@vueuse/core';
import { provideMessageContext } from './provider.js';
import { useTrack } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import { emitter } from 'shared/helpers/mitt';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { LocalStorage } from 'shared/helpers/localStorage';
import { ACCOUNT_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';
import {
  CHANNEL_ICON_NEUTRAL_CLASS,
  getInboxIconByType,
  INBOX_TYPES,
  TWILIO_CHANNEL_MEDIUM,
} from 'dashboard/helper/inbox';
import { useInbox } from 'dashboard/composables/useInbox';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import {
  MESSAGE_TYPES,
  ATTACHMENT_TYPES,
  MESSAGE_VARIANTS,
  SENDER_TYPES,
  ORIENTATION,
  MESSAGE_STATUS,
  CONTENT_TYPES,
} from './constants';
import { isAutomationTouchMessage } from './helpers/messageProvenance';
import {
  councilCaption,
  councilContributors,
  isCaptainAssistantSender,
} from './helpers/captainSender';
import { isAttachmentConfirmedPurged } from 'dashboard/composables/useAttachmentAvailability';

import Avatar from 'next/avatar/Avatar.vue';
import CaptainSenderAvatars from './CaptainSenderAvatars.vue';

import TextBubble from './bubbles/Text/Index.vue';
import ActivityBubble from './bubbles/Activity.vue';
import ImageBubble from './bubbles/Image.vue';
import FileBubble from './bubbles/File.vue';
import AudioBubble from './bubbles/Audio.vue';
import VideoBubble from './bubbles/Video.vue';
import EmbedBubble from './bubbles/Embed.vue';
import InstagramStoryBubble from './bubbles/InstagramStory.vue';
import EmailBubble from './bubbles/Email/Index.vue';
import UnsupportedBubble from './bubbles/Unsupported.vue';
import ContactBubble from './bubbles/Contact.vue';
import DyteBubble from './bubbles/Dyte.vue';
import LocationBubble from './bubbles/Location.vue';
import CSATBubble from './bubbles/CSAT.vue';
import FormBubble from './bubbles/Form.vue';
import VoiceCallBubble from './bubbles/VoiceCall.vue';

import MessageError from './MessageError.vue';
import ContextMenu from 'dashboard/modules/conversations/components/MessageContextMenu.vue';
import { useBranding } from 'shared/composables/useBranding';

/**
 * @typedef {Object} Attachment
 * @property {number} id - Unique identifier for the attachment
 * @property {number} messageId - ID of the associated message
 * @property {'image'|'audio'|'video'|'file'|'location'|'fallback'|'share'|'story_mention'|'contact'|'ig_reel'} fileType - Type of the attachment (file or image)
 * @property {number} accountId - ID of the associated account
 * @property {string|null} extension - File extension
 * @property {string} dataUrl - URL to access the full attachment data
 * @property {string} thumbUrl - URL to access the thumbnail version
 * @property {number} fileSize - Size of the file in bytes
 * @property {number|null} width - Width of the image if applicable
 * @property {number|null} height - Height of the image if applicable
 */

/**
 * @typedef {Object} Sender
 * @property {Object} additional_attributes - Additional attributes of the sender
 * @property {Object} custom_attributes - Custom attributes of the sender
 * @property {string} email - Email of the sender
 * @property {number} id - ID of the sender
 * @property {string|null} identifier - Identifier of the sender
 * @property {string} name - Name of the sender
 * @property {string|null} phone_number - Phone number of the sender
 * @property {string} thumbnail - Thumbnail URL of the sender
 * @property {string} type - Type of sender
 */

/**
 * @typedef {Object} ContentAttributes
 * @property {string} externalError - an error message to be shown if the message failed to send
 */

/**
 * @typedef {Object} Props
 * @property {('sent'|'delivered'|'read'|'failed'|'progress')} status - The delivery status of the message
 * @property {ContentAttributes} [contentAttributes={}] - Additional attributes of the message content
 * @property {Attachment[]} [attachments=[]] - The attachments associated with the message
 * @property {Sender|null} [sender=null] - The sender information
 * @property {boolean} [private=false] - Whether the message is private
 * @property {number|null} [senderId=null] - The ID of the sender
 * @property {number} createdAt - Timestamp when the message was created
 * @property {number} currentUserId - The ID of the current user
 * @property {number|string} id - The unique identifier for the message
 * @property {number} messageType - The type of message (must be one of MESSAGE_TYPES)
 * @property {string|null} [error=null] - Error message if the message failed to send
 * @property {string|null} [senderType=null] - The type of the sender
 * @property {string} content - The message content
 * @property {boolean} [groupWithNext=false] - Whether the message should be grouped with the next message
 * @property {Object|null} [inReplyTo=null] - The message to which this message is a reply
 * @property {boolean} [isEmailInbox=false] - Whether the message is from an email inbox
 * @property {number} conversationId - The ID of the conversation to which the message belongs
 * @property {number} inboxId - The ID of the inbox to which the message belongs
 */

// eslint-disable-next-line vue/define-macros-order
const props = defineProps({
  id: { type: [Number, String], required: true },
  messageType: {
    type: Number,
    required: true,
    validator: value => Object.values(MESSAGE_TYPES).includes(value),
  },
  status: {
    type: String,
    required: true,
    validator: value => Object.values(MESSAGE_STATUS).includes(value),
  },
  attachments: { type: Array, default: () => [] },
  content: { type: String, default: null },
  contentAttributes: { type: Object, default: () => ({}) },
  contentType: {
    type: String,
    default: 'text',
    validator: value => Object.values(CONTENT_TYPES).includes(value),
  },
  conversationId: { type: Number, required: true },
  createdAt: { type: Number, required: true }, // eslint-disable-line vue/no-unused-properties
  currentUserId: { type: Number, required: true }, // eslint-disable-line vue/no-unused-properties
  groupWithNext: { type: Boolean, default: false },
  inboxId: { type: Number, default: null }, // eslint-disable-line vue/no-unused-properties
  inboxSupportsReplyTo: { type: Object, default: () => ({}) },
  inReplyTo: { type: Object, default: null }, // eslint-disable-line vue/no-unused-properties
  isEmailInbox: { type: Boolean, default: false },
  private: { type: Boolean, default: false },
  additionalAttributes: { type: Object, default: () => ({}) }, // eslint-disable-line vue/no-unused-properties
  sender: { type: Object, default: null },
  senderId: { type: Number, default: null },
  senderType: { type: String, default: null },
  sourceId: { type: String, default: '' }, // eslint-disable-line vue/no-unused-properties
});

const emit = defineEmits(['retry']);

const contextMenuPosition = ref({});
const showBackgroundHighlight = ref(false);
const showContextMenu = ref(false);
const { t } = useI18n();
const route = useRoute();
const inboxGetter = useMapGetter('inboxes/getInbox');
const inbox = computed(() => inboxGetter.value(props.inboxId) || {});
const {
  isAWebWidgetInbox,
  isAWhatsAppCloudChannel,
  isAWhatsAppWebChannel,
  isATelegramChannel,
  isATelegramPersonalChannel,
} = useInbox(props.inboxId);
const { replaceInstallationName } = useBranding();

const withoutNeutralChannelColor = iconName =>
  iconName?.replace(CHANNEL_ICON_NEUTRAL_CLASS, '').trim() || '';

const EXTERNAL_ECHO_PLATFORM_I18N_KEYS = {
  [INBOX_TYPES.WEB]: 'INBOX_MGMT.CHANNELS.WEB_WIDGET',
  [INBOX_TYPES.FB]: 'INBOX_MGMT.CHANNELS.MESSENGER',
  [INBOX_TYPES.TWITTER]: 'INBOX_MGMT.CHANNELS.TWITTER_PROFILE',
  [INBOX_TYPES.TWILIO]: 'INBOX_MGMT.CHANNELS.TWILIO_SMS',
  [INBOX_TYPES.WHATSAPP]: 'INBOX_MGMT.CHANNELS.WHATSAPP',
  [INBOX_TYPES.WHATSAPP_WEB]: 'INBOX_MGMT.CHANNELS.WHATSAPP_WEB',
  [INBOX_TYPES.API]: 'INBOX_MGMT.CHANNELS.API',
  [INBOX_TYPES.EMAIL]: 'INBOX_MGMT.CHANNELS.EMAIL',
  [INBOX_TYPES.TELEGRAM]: 'INBOX_MGMT.CHANNELS.TELEGRAM_BOT',
  [INBOX_TYPES.TELEGRAM_PERSONAL]: 'INBOX_MGMT.CHANNELS.TELEGRAM_PERSONAL',
  [INBOX_TYPES.VK]: 'INBOX_MGMT.CHANNELS.VK',
  [INBOX_TYPES.LINE]: 'INBOX_MGMT.CHANNELS.LINE',
  [INBOX_TYPES.SMS]: 'INBOX_MGMT.CHANNELS.SMS',
  [INBOX_TYPES.INSTAGRAM]: 'INBOX_MGMT.CHANNELS.INSTAGRAM',
  [INBOX_TYPES.TIKTOK]: 'INBOX_MGMT.CHANNELS.TIKTOK',
  [INBOX_TYPES.VOICE]: 'INBOX_MGMT.CHANNELS.VOICE',
};

const externalEchoPlatformName = computed(() => {
  const { channel_type: channelType, medium, name } = inbox.value;

  if (
    channelType === INBOX_TYPES.TWILIO &&
    medium === TWILIO_CHANNEL_MEDIUM.WHATSAPP
  ) {
    return t('INBOX_MGMT.CHANNELS.WHATSAPP');
  }

  const i18nKey = EXTERNAL_ECHO_PLATFORM_I18N_KEYS[channelType];
  if (i18nKey) {
    // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
    return t(i18nKey);
  }

  return name || t('CONVERSATION.NATIVE_APP');
});

/**
 * Computes the message variant based on props
 * @type {import('vue').ComputedRef<'user'|'agent'|'activity'|'private'|'bot'|'template'>}
 */
const variant = computed(() => {
  if (props.private) return MESSAGE_VARIANTS.PRIVATE;

  if (props.isEmailInbox) {
    const emailInboxTypes = [MESSAGE_TYPES.INCOMING, MESSAGE_TYPES.OUTGOING];
    if (emailInboxTypes.includes(props.messageType)) {
      return MESSAGE_VARIANTS.EMAIL;
    }
  }

  if (props.contentType === CONTENT_TYPES.INCOMING_EMAIL) {
    return MESSAGE_VARIANTS.EMAIL;
  }

  if (props.status === MESSAGE_STATUS.FAILED) return MESSAGE_VARIANTS.ERROR;
  if (props.contentAttributes?.isUnsupported)
    return MESSAGE_VARIANTS.UNSUPPORTED;

  if (props.contentAttributes?.externalEcho) {
    return MESSAGE_VARIANTS.AGENT;
  }

  if (
    props.messageType === MESSAGE_TYPES.OUTGOING &&
    isAutomationTouchMessage(props.additionalAttributes)
  ) {
    return MESSAGE_VARIANTS.BOT;
  }

  const hasExternalSenderName = !!props.additionalAttributes?.senderName;
  const isBot =
    (!props.sender && !hasExternalSenderName) ||
    isCaptainAssistantSender(props.sender, props.senderType);
  if (isBot && props.messageType === MESSAGE_TYPES.OUTGOING) {
    return MESSAGE_VARIANTS.BOT;
  }

  const variants = {
    [MESSAGE_TYPES.INCOMING]: MESSAGE_VARIANTS.USER,
    [MESSAGE_TYPES.ACTIVITY]: MESSAGE_VARIANTS.ACTIVITY,
    [MESSAGE_TYPES.OUTGOING]: MESSAGE_VARIANTS.AGENT,
    [MESSAGE_TYPES.TEMPLATE]: MESSAGE_VARIANTS.TEMPLATE,
  };

  return variants[props.messageType] || MESSAGE_VARIANTS.USER;
});

const isBotOrAgentMessage = computed(() => {
  if (props.messageType === MESSAGE_TYPES.ACTIVITY) {
    return false;
  }
  // if an outgoing message is still processing, then it's definitely a
  // message sent by the current user
  if (
    props.status === MESSAGE_STATUS.PROGRESS &&
    props.messageType === MESSAGE_TYPES.OUTGOING
  ) {
    return true;
  }
  const senderId = props.senderId ?? props.sender?.id;
  const senderType = props.sender?.type ?? props.senderType;

  if (!senderType || !senderId) {
    return true;
  }

  if (isCaptainAssistantSender(props.sender, props.senderType)) {
    return true;
  }

  return senderType.toLowerCase() === SENDER_TYPES.USER.toLowerCase();
});

/**
 * Computes the message orientation based on sender type and message type
 * @returns {import('vue').ComputedRef<'left'|'right'|'center'>} The computed orientation
 */
const orientation = computed(() => {
  if (isBotOrAgentMessage.value) {
    return ORIENTATION.RIGHT;
  }

  if (props.messageType === MESSAGE_TYPES.ACTIVITY) return ORIENTATION.CENTER;

  return ORIENTATION.LEFT;
});

const flexOrientationClass = computed(() => {
  const map = {
    [ORIENTATION.LEFT]: 'justify-start',
    [ORIENTATION.RIGHT]: 'justify-end',
    [ORIENTATION.CENTER]: 'justify-center',
  };

  return map[orientation.value];
});

const gridTemplate = computed(() => {
  const map = {
    [ORIENTATION.LEFT]: `
      "avatar bubble"
      "spacer meta"
    `,
    [ORIENTATION.RIGHT]: `
      "bubble avatar"
      "meta spacer"
    `,
  };

  return map[orientation.value];
});

const shouldGroupWithNext = computed(() => {
  if (props.status === MESSAGE_STATUS.FAILED) return false;

  return props.groupWithNext;
});

const shouldShowAvatar = computed(() => {
  if (props.messageType === MESSAGE_TYPES.ACTIVITY) return false;

  return [ORIENTATION.LEFT, ORIENTATION.RIGHT].includes(orientation.value);
});

// Agents that answered together (council reply), normalized from the
// camelCase or snake_case payload.
const councilMembers = computed(() =>
  councilContributors({
    contentAttributes: props.contentAttributes,
    additionalAttributes: props.additionalAttributes,
  })
);

const shouldShowCouncilAvatars = computed(
  () =>
    orientation.value === ORIENTATION.RIGHT &&
    councilMembers.value.length > 0 &&
    !shouldGroupWithNext.value &&
    shouldShowAvatar.value
);

const councilCaptionText = computed(() => {
  if (!councilMembers.value.length) return '';

  return t('CAPTAIN.CHAT_AVATARS.COUNCIL_CAPTION', {
    names: councilCaption(councilMembers.value),
  });
});

const gridClass = computed(() => {
  // Stacked council avatars need more room than one 24px avatar.
  if (shouldShowCouncilAvatars.value) {
    return 'grid grid-cols-[minmax(0,1fr)_auto]';
  }

  const map = {
    [ORIENTATION.LEFT]: 'grid grid-cols-[24px_minmax(0,1fr)]',
    [ORIENTATION.RIGHT]: 'grid grid-cols-[minmax(0,1fr)_24px]',
  };

  return map[orientation.value];
});

const isVoiceNote = computed(() => {
  return !!(
    props.contentAttributes?.voiceNote || props.contentAttributes?.voice_note
  );
});

const componentToRender = computed(() => {
  if (props.isEmailInbox && !props.private) {
    const emailInboxTypes = [MESSAGE_TYPES.INCOMING, MESSAGE_TYPES.OUTGOING];
    if (emailInboxTypes.includes(props.messageType)) return EmailBubble;
  }

  if (props.contentType === CONTENT_TYPES.INPUT_CSAT) {
    return CSATBubble;
  }

  if (
    [CONTENT_TYPES.INPUT_SELECT, CONTENT_TYPES.FORM].includes(props.contentType)
  ) {
    return FormBubble;
  }

  if (props.contentType === CONTENT_TYPES.VOICE_CALL) {
    return VoiceCallBubble;
  }

  if (props.contentType === CONTENT_TYPES.INCOMING_EMAIL) {
    return EmailBubble;
  }

  if (props.contentAttributes?.isUnsupported) {
    return UnsupportedBubble;
  }

  if (props.contentAttributes.type === 'dyte') {
    return DyteBubble;
  }

  const instagramSharedTypes = [
    ATTACHMENT_TYPES.STORY_MENTION,
    ATTACHMENT_TYPES.IG_STORY,
    ATTACHMENT_TYPES.IG_STORY_REPLY,
    ATTACHMENT_TYPES.IG_POST,
  ];
  if (instagramSharedTypes.includes(props.contentAttributes.imageType)) {
    return InstagramStoryBubble;
  }

  if (Array.isArray(props.attachments) && props.attachments.length === 1) {
    const fileType = props.attachments[0].fileType;

    // A file purged from the storage trash has no media to play; the text bubble shows the note and transcript.
    if (
      props.attachments[0].filePurged === true ||
      props.attachments[0].file_purged === true ||
      isAttachmentConfirmedPurged(props.attachments[0], {
        accountId: route.params.accountId,
        conversationId: props.conversationId,
      })
    ) {
      return TextBubble;
    }

    if (
      isVoiceNote.value &&
      [ATTACHMENT_TYPES.AUDIO, ATTACHMENT_TYPES.FILE].includes(fileType)
    ) {
      return AudioBubble;
    }

    if (!props.content) {
      if (fileType === ATTACHMENT_TYPES.IMAGE) return ImageBubble;
      if (fileType === ATTACHMENT_TYPES.FILE) return FileBubble;
      if (fileType === ATTACHMENT_TYPES.AUDIO) return AudioBubble;
      if (fileType === ATTACHMENT_TYPES.VIDEO) return VideoBubble;
      if (fileType === ATTACHMENT_TYPES.IG_REEL) return VideoBubble;
      if (fileType === ATTACHMENT_TYPES.EMBED) return EmbedBubble;
      if (fileType === ATTACHMENT_TYPES.LOCATION) return LocationBubble;
    }
    // Attachment content is the name of the contact
    if (fileType === ATTACHMENT_TYPES.CONTACT) return ContactBubble;
  }

  return TextBubble;
});

const shouldShowContextMenu = computed(() => {
  return !props.contentAttributes?.isUnsupported;
});

const isBubble = computed(() => {
  return props.messageType !== MESSAGE_TYPES.ACTIVITY;
});

const isMessageDeleted = computed(() => {
  return props.contentAttributes?.deleted;
});

const payloadForContextMenu = computed(() => {
  return {
    id: props.id,
    content_attributes: props.contentAttributes,
    content: props.content,
    conversation_id: props.conversationId,
    currentUserId: props.currentUserId,
  };
});

const contextMenuEnabledOptions = computed(() => {
  const hasText = !!props.content;
  const hasAttachments = !!(props.attachments && props.attachments.length > 0);
  const hasContent = hasText || hasAttachments;
  const firstAttachmentType = props.attachments?.[0]?.fileType;
  const createdAt =
    Number(props.createdAt) > 1000000000000
      ? Math.floor(Number(props.createdAt) / 1000)
      : Number(props.createdAt);
  const messageAgeSeconds = Math.floor(Date.now() / 1000) - createdAt;

  const isOutgoing = props.messageType === MESSAGE_TYPES.OUTGOING;
  const isFailedOrProcessing =
    props.status === MESSAGE_STATUS.FAILED ||
    props.status === MESSAGE_STATUS.PROGRESS;
  const isWithinEditWindow = messageAgeSeconds <= 15 * 60;
  const isWithinDeleteWindow = messageAgeSeconds <= 48 * 60 * 60;
  const canEditOnTelegram =
    (isATelegramChannel?.value && isWithinDeleteWindow) ||
    isATelegramPersonalChannel?.value;
  const canReactOnChannel =
    isAWhatsAppCloudChannel?.value ||
    isAWhatsAppWebChannel?.value ||
    isATelegramChannel?.value ||
    isATelegramPersonalChannel?.value;
  const isEditableAttachment =
    !hasAttachments ||
    (props.attachments.length === 1 &&
      ['image', 'video'].includes(firstAttachmentType));
  const canDeleteOnProvider =
    isOutgoing &&
    !!props.sourceId &&
    !props.private &&
    (isATelegramPersonalChannel?.value ||
      ((isAWhatsAppWebChannel?.value || isATelegramChannel?.value) &&
        isWithinDeleteWindow));
  const canDeleteLocally =
    hasContent && (props.private || !!isAWebWidgetInbox?.value);

  return {
    edit:
      ((isAWhatsAppWebChannel?.value && isWithinEditWindow) ||
        canEditOnTelegram) &&
      isOutgoing &&
      hasText &&
      !!props.sourceId &&
      !props.private &&
      !isFailedOrProcessing &&
      !isMessageDeleted.value &&
      isEditableAttachment,
    copy: hasText,
    delete:
      !isFailedOrProcessing &&
      !isMessageDeleted.value &&
      (canDeleteLocally || canDeleteOnProvider),
    cannedResponse: isOutgoing && hasText && !isMessageDeleted.value,
    copyLink: !isFailedOrProcessing,
    translate: !isFailedOrProcessing && !isMessageDeleted.value && hasText,
    replyTo:
      !props.private &&
      props.inboxSupportsReplyTo.outgoing &&
      !isFailedOrProcessing,
    react:
      canReactOnChannel &&
      !props.private &&
      !!props.sourceId &&
      !isFailedOrProcessing &&
      !isMessageDeleted.value &&
      isBubble.value,
  };
});

const shouldRenderMessage = computed(() => {
  const hasAttachments = !!(props.attachments && props.attachments.length > 0);
  const isEmailContentType = props.contentType === CONTENT_TYPES.INCOMING_EMAIL;
  const isUnsupported = props.contentAttributes?.isUnsupported;
  const isAnIntegrationMessage =
    props.contentType === CONTENT_TYPES.INTEGRATIONS;
  const isFailedMessage = props.status === MESSAGE_STATUS.FAILED;
  const hasExternalError = !!props.contentAttributes?.externalError;

  return (
    hasAttachments ||
    props.content ||
    isEmailContentType ||
    isUnsupported ||
    isAnIntegrationMessage ||
    isFailedMessage ||
    hasExternalError
  );
});

function openContextMenu(e) {
  const shouldSkipContextMenu =
    e.target?.classList.contains('skip-context-menu') ||
    ['a', 'img'].includes(e.target?.tagName.toLowerCase());
  if (shouldSkipContextMenu || getSelection().toString()) {
    return;
  }

  e.preventDefault();
  if (e.type === 'contextmenu') {
    useTrack(ACCOUNT_EVENTS.OPEN_MESSAGE_CONTEXT_MENU);
  }
  contextMenuPosition.value = {
    x: e.pageX || e.clientX,
    y: e.pageY || e.clientY,
  };
  showContextMenu.value = true;
}

function openContextMenuFromButton(e) {
  e.preventDefault();
  const rect = e.currentTarget?.getBoundingClientRect?.();
  contextMenuPosition.value = {
    x: rect ? rect.left : e.pageX || e.clientX,
    y: rect ? rect.bottom + 4 : e.pageY || e.clientY,
  };
  showContextMenu.value = true;
}

function closeContextMenu() {
  showContextMenu.value = false;
  contextMenuPosition.value = { x: null, y: null };
}

function handleReplyTo() {
  const replyStorageKey = LOCAL_STORAGE_KEYS.MESSAGE_REPLY_TO;
  const { conversationId, id: replyTo } = props;

  LocalStorage.updateJsonStore(replyStorageKey, conversationId, replyTo);
  emitter.emit(BUS_EVENTS.TOGGLE_REPLY_TO_MESSAGE, props);
}

function handleEdit() {
  emitter.emit(BUS_EVENTS.TOGGLE_EDIT_MESSAGE, props);
}

const avatarInfo = computed(() => {
  if (orientation.value === ORIENTATION.LEFT) {
    const { channel_type: channelType, medium } = inbox.value;
    const iconName = withoutNeutralChannelColor(
      getInboxIconByType(channelType, medium, 'line')
    );

    return {
      name: '',
      src: '',
      iconName,
    };
  }

  if (
    props.messageType === MESSAGE_TYPES.OUTGOING &&
    isAutomationTouchMessage(props.additionalAttributes) &&
    !isCaptainAssistantSender(props.sender, props.senderType)
  ) {
    return {
      name: t('CONVERSATION.AUTOMATION_SYSTEM'),
      src: '',
      iconName: 'i-lucide-workflow',
    };
  }

  if (props.contentAttributes?.externalEcho) {
    const { name, avatar_url, channel_type, medium } = inbox.value;
    const iconName = avatar_url
      ? null
      : getInboxIconByType(channel_type, medium);
    return {
      name: iconName ? '' : name || t('CONVERSATION.NATIVE_APP'),
      src: avatar_url || '',
      iconName,
    };
  }

  // If no sender, check for Slack (or other integration) sender info
  if (!props.sender) {
    const { senderName, senderAvatarUrl } = props.additionalAttributes || {};
    if (senderName) {
      return { name: senderName, src: senderAvatarUrl ?? '' };
    }
    return { name: t('CONVERSATION.BOT'), src: '' };
  }

  const { sender } = props;
  const { name, avatarUrl, thumbnail } = sender || {};

  // AI agent: its photo, or the Captain icon colored by its name.
  if (isCaptainAssistantSender(sender, props.senderType)) {
    const agentName = String(name ?? '').trim();
    const src = avatarUrl || '';

    return {
      name: agentName,
      src,
      iconName: src ? null : 'i-woot-captain',
    };
  }

  // For all other senders, use thumbnail
  return {
    name: name ?? '',
    src: thumbnail ?? '',
  };
});

const avatarTooltip = computed(() => {
  if (props.contentAttributes?.externalEcho) {
    return replaceInstallationName(
      t('CONVERSATION.NATIVE_APP_ADVISORY', {
        platform: externalEchoPlatformName.value,
      })
    );
  }
  if (shouldShowCouncilAvatars.value) return councilCaptionText.value;
  if (avatarInfo.value.name === '') return '';
  return `${t('CONVERSATION.SENT_BY')} ${avatarInfo.value.name}`;
});

const setupHighlightTimer = () => {
  if (Number(route.query.messageId) !== Number(props.id)) {
    return;
  }

  showBackgroundHighlight.value = true;
  const HIGHLIGHT_TIMER = 1000;
  useTimeoutFn(() => {
    showBackgroundHighlight.value = false;
  }, HIGHLIGHT_TIMER);
};

onMounted(setupHighlightTimer);

provideMessageContext({
  ...toRefs(props),
  isPrivate: computed(() => props.private),
  variant,
  orientation,
  isBotOrAgentMessage,
  shouldGroupWithNext,
  canReact: computed(() => contextMenuEnabledOptions.value.react),
});
</script>

<!-- eslint-disable-next-line vue/no-root-v-if -->
<template>
  <div
    v-if="shouldRenderMessage"
    :id="`message${props.id}`"
    class="flex w-full mb-2 message-bubble-container"
    :data-message-id="props.id"
    :class="[
      flexOrientationClass,
      {
        'group-with-next': shouldGroupWithNext,
        'bg-n-alpha-1': showBackgroundHighlight,
      },
    ]"
  >
    <div v-if="variant === MESSAGE_VARIANTS.ACTIVITY">
      <ActivityBubble :content="content" />
    </div>
    <div
      v-else
      :class="[
        gridClass,
        {
          'gap-y-2': contentAttributes.externalError,
          'w-full': variant === MESSAGE_VARIANTS.EMAIL,
        },
      ]"
      class="gap-x-2 w-full max-w-full min-w-0"
      :style="{
        gridTemplateAreas: gridTemplate,
      }"
    >
      <div
        v-if="!shouldGroupWithNext && shouldShowAvatar"
        v-tooltip.left-end="avatarTooltip"
        class="[grid-area:avatar] flex items-end"
      >
        <CaptainSenderAvatars
          v-if="shouldShowCouncilAvatars"
          :contributors="councilMembers"
          :size="24"
        />
        <Avatar v-else v-bind="avatarInfo" :size="24" />
      </div>
      <div
        class="[grid-area:bubble] flex items-center gap-1 max-w-full min-w-0 group/message-bubble"
        :class="{
          'ltr:ml-8 rtl:mr-8 justify-end': orientation === ORIENTATION.RIGHT,
          'ltr:mr-8 rtl:ml-8': orientation === ORIENTATION.LEFT,
          'min-w-0': variant === MESSAGE_VARIANTS.EMAIL,
        }"
        @contextmenu="openContextMenu($event)"
      >
        <button
          v-if="
            contextMenuEnabledOptions.react &&
            orientation === ORIENTATION.RIGHT &&
            variant !== MESSAGE_VARIANTS.EMAIL
          "
          type="button"
          :title="$t('CONVERSATION.REACTIONS.ADD')"
          data-testid="message-quick-react-trigger"
          class="opacity-0 group-hover/message-bubble:opacity-100 focus:opacity-100 transition-opacity duration-150 inline-flex items-center justify-center w-6 h-6 rounded-full text-n-slate-10 hover:text-n-slate-12 hover:bg-n-alpha-2 shrink-0 skip-context-menu cursor-pointer"
          @click.stop="openContextMenuFromButton($event)"
        >
          <span class="i-lucide-smile-plus size-3.5 skip-context-menu" />
        </button>
        <Component :is="componentToRender" />
        <button
          v-if="
            contextMenuEnabledOptions.react &&
            orientation === ORIENTATION.LEFT &&
            variant !== MESSAGE_VARIANTS.EMAIL
          "
          type="button"
          :title="$t('CONVERSATION.REACTIONS.ADD')"
          data-testid="message-quick-react-trigger"
          class="opacity-0 group-hover/message-bubble:opacity-100 focus:opacity-100 transition-opacity duration-150 inline-flex items-center justify-center w-6 h-6 rounded-full text-n-slate-10 hover:text-n-slate-12 hover:bg-n-alpha-2 shrink-0 skip-context-menu cursor-pointer"
          @click.stop="openContextMenuFromButton($event)"
        >
          <span class="i-lucide-smile-plus size-3.5 skip-context-menu" />
        </button>
      </div>
      <MessageError
        v-if="contentAttributes.externalError"
        class="[grid-area:meta]"
        :class="flexOrientationClass"
        :error="contentAttributes.externalError"
        @retry="emit('retry')"
      />
    </div>
    <div v-if="shouldShowContextMenu" class="context-menu-wrap">
      <ContextMenu
        v-if="isBubble"
        :context-menu-position="contextMenuPosition"
        :is-open="showContextMenu"
        :enabled-options="contextMenuEnabledOptions"
        :message="payloadForContextMenu"
        hide-button
        @open="openContextMenu"
        @close="closeContextMenu"
        @edit="handleEdit"
        @reply-to="handleReplyTo"
      />
    </div>
  </div>
</template>

<style lang="scss">
.group-with-next + .message-bubble-container {
  .left-bubble {
    @apply ltr:rounded-tl-sm rtl:rounded-tr-sm;
  }

  .right-bubble {
    @apply ltr:rounded-tr-sm rtl:rounded-tl-sm;
  }
}
</style>
