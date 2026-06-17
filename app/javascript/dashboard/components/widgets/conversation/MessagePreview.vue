<script>
import { MESSAGE_TYPE } from 'widget/helpers/constants';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import { ATTACHMENT_ICONS } from 'shared/constants/messages';
import { getLocalizedActivityMessage } from 'dashboard/helper/activityMessageHelper';

export default {
  name: 'MessagePreview',
  props: {
    message: {
      type: Object,
      required: true,
    },
    showMessageType: {
      type: Boolean,
      default: true,
    },
    defaultEmptyMessage: {
      type: String,
      default: '',
    },
  },
  setup() {
    const { getPlainText } = useMessageFormatter();
    return {
      getPlainText,
    };
  },
  computed: {
    messageByAgent() {
      const { message_type: messageType } = this.message;
      return messageType === MESSAGE_TYPE.OUTGOING;
    },
    isMessageAnActivity() {
      const { message_type: messageType } = this.message;
      return messageType === MESSAGE_TYPE.ACTIVITY;
    },
    isMessagePrivate() {
      const { private: isPrivate } = this.message;
      return isPrivate;
    },
    parsedLastMessage() {
      const { content_attributes: contentAttributes } = this.message;
      const { email: { subject } = {} } = contentAttributes || {};
      const content = subject || this.message.content;
      return this.getPlainText(
        this.isMessageAnActivity
          ? getLocalizedActivityMessage(content, this.$t.bind(this))
          : content
      );
    },
    isVoiceNote() {
      const { content_attributes: contentAttributes = {} } = this.message;
      return !!(contentAttributes.voice_note || contentAttributes.voiceNote);
    },
    lastMessageFileType() {
      if (this.isVoiceNote) {
        return 'audio';
      }
      const [{ file_type: fileType } = {}] = this.message.attachments;
      return fileType;
    },
    attachmentIcon() {
      return ATTACHMENT_ICONS[this.lastMessageFileType];
    },
    attachmentMessageContent() {
      const contentMap = {
        image: this.$t('CHAT_LIST.ATTACHMENTS.image.CONTENT'),
        audio: this.$t('CHAT_LIST.ATTACHMENTS.audio.CONTENT'),
        video: this.$t('CHAT_LIST.ATTACHMENTS.video.CONTENT'),
        file: this.$t('CHAT_LIST.ATTACHMENTS.file.CONTENT'),
        location: this.$t('CHAT_LIST.ATTACHMENTS.location.CONTENT'),
        ig_reel: this.$t('CHAT_LIST.ATTACHMENTS.ig_reel.CONTENT'),
        fallback: this.$t('CHAT_LIST.ATTACHMENTS.fallback.CONTENT'),
        contact: this.$t('CHAT_LIST.ATTACHMENTS.contact.CONTENT'),
        embed: this.$t('CHAT_LIST.ATTACHMENTS.embed.CONTENT'),
      };

      return contentMap[this.lastMessageFileType] || this.defaultEmptyMessage;
    },
    isMessageSticker() {
      return this.message && this.message.content_type === 'sticker';
    },
  },
};
</script>

<template>
  <div class="overflow-hidden text-ellipsis whitespace-nowrap">
    <template v-if="showMessageType">
      <fluent-icon
        v-if="isMessagePrivate"
        size="16"
        class="-mt-0.5 align-middle text-n-slate-11 inline-block"
        icon="lock-closed"
      />
      <fluent-icon
        v-else-if="messageByAgent"
        size="16"
        class="-mt-0.5 align-middle text-n-slate-11 inline-block"
        icon="arrow-reply"
      />
      <fluent-icon
        v-else-if="isMessageAnActivity"
        size="16"
        class="-mt-0.5 align-middle text-n-slate-11 inline-block"
        icon="info"
      />
    </template>
    <span v-if="message.content && isMessageSticker">
      <fluent-icon
        size="16"
        class="-mt-0.5 align-middle inline-block text-n-slate-11"
        icon="image"
      />
      {{ $t('CHAT_LIST.ATTACHMENTS.image.CONTENT') }}
    </span>
    <span v-else-if="message.content">
      {{ parsedLastMessage }}
    </span>
    <span v-else-if="message.attachments">
      <fluent-icon
        v-if="attachmentIcon && showMessageType"
        size="16"
        class="-mt-0.5 align-middle inline-block text-n-slate-11"
        :icon="attachmentIcon"
      />
      {{ attachmentMessageContent }}
    </span>
    <span v-else>
      {{ defaultEmptyMessage || $t('CHAT_LIST.NO_CONTENT') }}
    </span>
  </div>
</template>
