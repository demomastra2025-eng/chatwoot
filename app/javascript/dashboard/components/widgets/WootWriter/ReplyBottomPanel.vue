<script>
import { ref } from 'vue';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';
import FileUpload from 'vue-upload-component';
import * as ActiveStorage from 'activestorage';
import inboxMixin from 'shared/mixins/inboxMixin';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { getAllowedFileTypesByChannel } from '@chatwoot/utils';
import { ALLOWED_FILE_TYPES } from 'shared/constants/messages';
import VideoCallButton from '../VideoCallButton.vue';
import { useWhatsappCallInitiation } from 'dashboard/composables/useWhatsappCallInitiation';
import PaymentActionButton from '../PaymentActionButton.vue';
import { INBOX_TYPES, getInboxIconByType } from 'dashboard/helper/inbox';
import { getCommunicationChannelLabel } from 'dashboard/helper/communicationThreadHelper';
import { mapGetters } from 'vuex';
import NextButton from 'dashboard/components-next/button/Button.vue';
import VoiceCallButton from 'dashboard/components-next/Contacts/VoiceCallButton.vue';
import wootConstants from 'dashboard/constants/globals';

export default {
  name: 'ReplyBottomPanel',
  components: {
    NextButton,
    FileUpload,
    PaymentActionButton,
    VideoCallButton,
    VoiceCallButton,
  },
  mixins: [inboxMixin],
  props: {
    isNote: {
      type: Boolean,
      default: false,
    },
    onSend: {
      type: Function,
      default: () => {},
    },
    sendButtonText: {
      type: String,
      default: '',
    },
    showCommunicationChannelSelector: {
      type: Boolean,
      default: false,
    },
    communicationChannels: {
      type: Array,
      default: () => [],
    },
    activeReplyChannel: {
      type: Object,
      default: null,
    },
    recordingAudioDurationText: {
      type: String,
      default: '00:00',
    },
    // inbox prop is used in /mixins/inboxMixin,
    // remove this props when refactoring to composable if not needed
    // eslint-disable-next-line vue/no-unused-properties
    inbox: {
      type: Object,
      default: () => ({}),
    },
    showFileUpload: {
      type: Boolean,
      default: false,
    },
    showAudioRecorder: {
      type: Boolean,
      default: false,
    },
    onFileUpload: {
      type: Function,
      default: () => {},
    },
    toggleEmojiPicker: {
      type: Function,
      default: () => {},
    },
    toggleAudioRecorder: {
      type: Function,
      default: () => {},
    },
    clearAudioRecorder: {
      type: Function,
      default: () => {},
    },
    toggleAudioRecorderPlayPause: {
      type: Function,
      default: () => {},
    },
    isRecordingAudio: {
      type: Boolean,
      default: false,
    },
    recordingAudioState: {
      type: String,
      default: '',
    },
    isSendDisabled: {
      type: Boolean,
      default: false,
    },
    isOnPrivateNote: {
      type: Boolean,
      default: false,
    },
    enableMultipleFileUpload: {
      type: Boolean,
      default: true,
    },
    enableWhatsAppTemplates: {
      type: Boolean,
      default: false,
    },
    enableContentTemplates: {
      type: Boolean,
      default: false,
    },
    conversationId: {
      type: Number,
      default: null,
    },
    contactId: {
      type: [Number, String],
      default: null,
    },
    contactPhone: {
      type: String,
      default: '',
    },
    // eslint-disable-next-line vue/no-unused-properties
    message: {
      type: String,
      default: '',
    },
    newConversationModalActive: {
      type: Boolean,
      default: false,
    },
    portalSlug: {
      type: String,
      required: true,
    },
    conversationType: {
      type: String,
      default: '',
    },
    showQuotedReplyToggle: {
      type: Boolean,
      default: false,
    },
    quotedReplyEnabled: {
      type: Boolean,
      default: false,
    },
    isEditorDisabled: {
      type: Boolean,
      default: false,
    },
  },
  emits: [
    'toggleInsertArticle',
    'selectWhatsappTemplate',
    'selectContentTemplate',
    'selectReplyChannel',
    'toggleQuotedReply',
    'replaceText',
    'attachFile',
  ],
  setup(props) {
    const { setSignatureFlagForInbox, fetchSignatureFlagFromUISettings } =
      useUISettings();
    const {
      canInitiateWhatsappCall,
      initiateWhatsappCall,
      isInitiatingWhatsappCall,
    } = useWhatsappCallInitiation();

    const uploadRef = ref(false);

    const keyboardEvents = {
      '$mod+Alt+KeyA': {
        action: () => {
          // Skip if editor is disabled (e.g., WhatsApp 24-hour window expired)
          if (props.isEditorDisabled) return;

          // TODO: This is really hacky, we need to replace the file picker component with
          // a custom one, where the logic and the component markup is isolated.
          // Once we have the custom component, we can remove the hacky logic below.

          const uploadTriggerButton = document.querySelector(
            '#conversationAttachment'
          );
          if (uploadTriggerButton) uploadTriggerButton.click();
        },
        allowOnFocusedInput: true,
      },
    };

    useKeyboardEvents(keyboardEvents);

    return {
      setSignatureFlagForInbox,
      fetchSignatureFlagFromUISettings,
      uploadRef,
      canInitiateWhatsappCall,
      initiateWhatsappCall,
      isInitiatingWhatsappCall,
    };
  },
  data() {
    return {
      ALLOWED_FILE_TYPES,
      isTogglingCaptain: false,
      showReplyChannelDropdown: false,
    };
  },
  computed: {
    ...mapGetters({
      accountId: 'getCurrentAccountId',
      isFeatureEnabledonAccount: 'accounts/isFeatureEnabledonAccount',
      uiFlags: 'integrations/getUIFlags',
    }),
    currentConversation() {
      return this.$store.getters.getConversationById(this.conversationId) || {};
    },
    showReplyChannelMenu() {
      return (
        this.showCommunicationChannelSelector &&
        this.communicationChannels.length > 1
      );
    },
    activeReplyChannelIcon() {
      return this.replyChannelIcon(this.activeReplyChannel);
    },
    activeReplyChannelLabel() {
      return this.replyChannelLabel(this.activeReplyChannel);
    },
    activeReplyChannelTooltip() {
      if (!this.showReplyChannelMenu || !this.activeReplyChannelLabel)
        return '';

      return this.$t('CONVERSATION.COMMUNICATION_THREAD.ACTIVE_CHANNEL', {
        channel: this.activeReplyChannelLabel,
      });
    },
    wrapClass() {
      return {
        'is-note-mode': this.isNote,
      };
    },
    showAttachButton() {
      if (this.isEditorDisabled) return false;
      return this.showFileUpload || this.isNote;
    },
    showAudioRecorderButton() {
      if (this.isEditorDisabled) return false;
      if (this.isALineChannel || this.isATiktokChannel) {
        return false;
      }
      // Disable audio recorder for safari browser as recording is not supported
      // const isSafari = /^((?!chrome|android|crios|fxios).)*safari/i.test(
      //   navigator.userAgent
      // );

      return (
        this.isFeatureEnabledonAccount(
          this.accountId,
          FEATURE_FLAGS.VOICE_RECORDER
        ) && this.showAudioRecorder
        // !isSafari
      );
    },
    showAudioPlayStopButton() {
      if (this.isEditorDisabled) return false;
      return this.showAudioRecorder && this.isRecordingAudio;
    },
    showAudioClearButton() {
      if (this.isEditorDisabled) return false;
      return this.showAudioRecorder && this.isRecordingAudio;
    },
    isInstagramDM() {
      return this.conversationType === 'instagram_direct_message';
    },
    allowedFileTypes() {
      // Use default file types for private notes
      if (this.isOnPrivateNote) {
        return this.ALLOWED_FILE_TYPES;
      }

      let channelType = this.channelType || this.inbox?.channel_type;

      if (this.isAnInstagramChannel || this.isInstagramDM) {
        channelType = INBOX_TYPES.INSTAGRAM;
      }

      return getAllowedFileTypesByChannel({
        channelType,
        medium: this.inbox?.medium,
      });
    },
    enableDragAndDrop() {
      return !this.newConversationModalActive;
    },
    audioRecorderPlayStopIcon() {
      switch (this.recordingAudioState) {
        // playing paused recording stopped inactive destroyed
        case 'playing':
          return 'i-ph-pause';
        case 'paused':
          return 'i-ph-play';
        case 'stopped':
          return 'i-ph-play';
        default:
          return 'i-ph-stop';
      }
    },
    showMessageSignatureButton() {
      if (this.isEditorDisabled) return false;
      return !this.isOnPrivateNote && this.isAnEmailChannel;
    },
    sendWithSignature() {
      // channelType is sourced from inboxMixin
      return this.isAnEmailChannel
        ? this.fetchSignatureFlagFromUISettings(this.channelType)
        : false;
    },
    signatureToggleTooltip() {
      return this.sendWithSignature
        ? this.$t('CONVERSATION.FOOTER.DISABLE_SIGN_TOOLTIP')
        : this.$t('CONVERSATION.FOOTER.ENABLE_SIGN_TOOLTIP');
    },
    enableInsertArticleInReply() {
      return this.portalSlug;
    },
    isFetchingAppIntegrations() {
      return this.uiFlags.isFetching;
    },
    quotedReplyToggleTooltip() {
      return this.quotedReplyEnabled
        ? this.$t('CONVERSATION.REPLYBOX.QUOTED_REPLY.DISABLE_TOOLTIP')
        : this.$t('CONVERSATION.REPLYBOX.QUOTED_REPLY.ENABLE_TOOLTIP');
    },
    showCaptainToggleButton() {
      if (this.isEditorDisabled) return false;
      if (this.isNote || this.isOnPrivateNote) return false;

      const isCaptainEnabledOnAccount = this.isFeatureEnabledonAccount(
        this.accountId,
        FEATURE_FLAGS.CAPTAIN
      );
      if (!isCaptainEnabledOnAccount) return false;

      return !!this.inbox?.captain_assistant?.id;
    },
    showVoiceCallButton() {
      if (this.isEditorDisabled) return false;
      if (this.isNote || this.isOnPrivateNote) return false;

      return Boolean(this.contactId && this.contactPhone);
    },
    isCaptainEnabledForConversation() {
      return (
        this.currentConversation?.status === wootConstants.STATUS_TYPE.PENDING
      );
    },
    captainToggleTooltip() {
      return this.isCaptainEnabledForConversation
        ? this.$t('CONVERSATION.FOOTER.CAPTAIN_DISABLE_TOOLTIP')
        : this.$t('CONVERSATION.FOOTER.CAPTAIN_ENABLE_TOOLTIP');
    },
  },
  mounted() {
    ActiveStorage.start();
  },
  methods: {
    replyChannelIcon(channel) {
      return channel?.channel
        ? getInboxIconByType(channel.channel, channel.medium)
        : '';
    },
    replyChannelLabel(channel) {
      return getCommunicationChannelLabel(channel);
    },
    isSelectedReplyChannel(channel) {
      return (
        String(channel?.channel_key || channel?.conversation_id) ===
        String(
          this.activeReplyChannel?.channel_key ||
            this.activeReplyChannel?.conversation_id
        )
      );
    },
    closeReplyChannelDropdown() {
      this.showReplyChannelDropdown = false;
    },
    toggleReplyChannelDropdown() {
      this.showReplyChannelDropdown = !this.showReplyChannelDropdown;
    },
    selectReplyChannel(channel) {
      this.$emit(
        'selectReplyChannel',
        channel.channel_key || channel.conversation_id
      );
      this.closeReplyChannelDropdown();
    },
    toggleMessageSignature() {
      this.setSignatureFlagForInbox(this.channelType, !this.sendWithSignature);
    },
    toggleInsertArticle() {
      this.$emit('toggleInsertArticle');
    },
    replaceText(text) {
      this.$emit('replaceText', text);
    },
    async toggleCaptainForConversation() {
      if (this.isTogglingCaptain) return;
      if (!this.showCaptainToggleButton) return;

      this.isTogglingCaptain = true;
      const currentUser = this.$store.getters.getCurrentUser;

      try {
        if (this.isCaptainEnabledForConversation) {
          await this.$store.dispatch('toggleStatus', {
            conversationId: this.conversationId,
            status: wootConstants.STATUS_TYPE.OPEN,
          });

          const assignee = this.currentConversation?.meta?.assignee;
          const needsAssignmentToCurrentUser =
            !assignee || assignee.id !== currentUser?.id;

          if (needsAssignmentToCurrentUser && currentUser?.id) {
            const { avatar_url, ...rest } = currentUser || {};
            this.$store.dispatch('setCurrentChatAssignee', {
              conversationId: this.conversationId,
              assignee: { ...rest, thumbnail: avatar_url },
            });
            await this.$store.dispatch('assignAgent', {
              conversationId: this.conversationId,
              agentId: currentUser.id,
            });
          }
        } else {
          await this.$store.dispatch('toggleStatus', {
            conversationId: this.conversationId,
            status: wootConstants.STATUS_TYPE.PENDING,
          });
        }
      } finally {
        this.isTogglingCaptain = false;
      }
    },
  },
};
</script>

<template>
  <div class="flex justify-between px-3 py-2.5" :class="wrapClass">
    <div class="left-wrap">
      <NextButton
        v-if="!isEditorDisabled"
        v-tooltip.top-end="$t('CONVERSATION.REPLYBOX.TIP_EMOJI_ICON')"
        icon="i-ph-smiley-sticker"
        slate
        faded
        sm
        @click="toggleEmojiPicker"
      />
      <FileUpload
        v-if="showAttachButton"
        ref="uploadRef"
        v-tooltip.top-end="$t('CONVERSATION.REPLYBOX.TIP_ATTACH_ICON')"
        input-id="conversationAttachment"
        :size="4096 * 4096"
        :accept="allowedFileTypes"
        :multiple="enableMultipleFileUpload"
        :drop="enableDragAndDrop"
        :drop-directory="false"
        :data="{
          direct_upload_url: '/rails/active_storage/direct_uploads',
          direct_upload: true,
        }"
        @input-file="onFileUpload"
      >
        <NextButton
          v-if="showAttachButton"
          v-tooltip.top-end="$t('CONVERSATION.REPLYBOX.TIP_ATTACH_ICON')"
          icon="i-ph-paperclip"
          slate
          faded
          sm
        />
      </FileUpload>
      <NextButton
        v-if="showAudioRecorderButton"
        v-tooltip.top-end="$t('CONVERSATION.REPLYBOX.TIP_AUDIORECORDER_ICON')"
        :icon="!isRecordingAudio ? 'i-ph-microphone' : 'i-ph-microphone-slash'"
        slate
        faded
        sm
        @click="toggleAudioRecorder"
      />
      <NextButton
        v-if="showAudioPlayStopButton"
        :icon="audioRecorderPlayStopIcon"
        slate
        faded
        sm
        :label="recordingAudioDurationText"
        @click="toggleAudioRecorderPlayPause"
      />
      <NextButton
        v-if="showAudioClearButton"
        v-tooltip.top-end="$t('CONVERSATION.REPLYBOX.TIP_AUDIORECORDER_CLEAR')"
        icon="i-lucide-x"
        slate
        faded
        sm
        @click="clearAudioRecorder"
      />
      <NextButton
        v-if="showMessageSignatureButton"
        v-tooltip.top-end="signatureToggleTooltip"
        icon="i-ph-signature"
        slate
        faded
        sm
        @click="toggleMessageSignature"
      />
      <NextButton
        v-if="showCaptainToggleButton"
        v-tooltip.top-end="captainToggleTooltip"
        icon="i-woot-captain"
        :variant="isCaptainEnabledForConversation ? 'solid' : 'faded'"
        color="slate"
        sm
        :aria-pressed="isCaptainEnabledForConversation"
        :disabled="isTogglingCaptain"
        :class="
          isCaptainEnabledForConversation
            ? '!bg-n-violet-3 !text-n-violet-9 hover:enabled:!bg-n-violet-4 focus-visible:!bg-n-violet-4 !outline-transparent'
            : ''
        "
        @click="toggleCaptainForConversation"
      />
      <VoiceCallButton
        v-if="showVoiceCallButton"
        v-tooltip.top-end="$t('CONTACT_PANEL.CALL')"
        :contact-id="contactId"
        :phone="contactPhone"
        icon="i-ph-phone"
        slate
        faded
        sm
      />
      <NextButton
        v-if="showQuotedReplyToggle"
        v-tooltip.top-end="quotedReplyToggleTooltip"
        icon="i-ph-quotes"
        :variant="quotedReplyEnabled ? 'solid' : 'faded'"
        color="slate"
        sm
        :aria-pressed="quotedReplyEnabled"
        @click="$emit('toggleQuotedReply')"
      />
      <PaymentActionButton
        v-if="!isOnPrivateNote && !isEditorDisabled"
        :conversation-id="conversationId"
        @replace-text="replaceText"
        @attach-file="$emit('attachFile', $event)"
      />
      <NextButton
        v-if="canInitiateWhatsappCall && !isOnPrivateNote && !isEditorDisabled"
        v-tooltip.top-end="$t('WHATSAPP_CALL.INITIATE_CALL')"
        icon="i-ph-phone"
        slate
        faded
        sm
        :is-loading="isInitiatingWhatsappCall"
        :disabled="isInitiatingWhatsappCall"
        @click="initiateWhatsappCall"
      />
      <NextButton
        v-if="enableWhatsAppTemplates"
        v-tooltip.top-end="$t('CONVERSATION.FOOTER.WHATSAPP_TEMPLATES')"
        icon="i-ph-whatsapp-logo"
        slate
        faded
        sm
        @click="$emit('selectWhatsappTemplate')"
      />
      <NextButton
        v-if="enableContentTemplates"
        v-tooltip.top-end="'Content Templates'"
        icon="i-ph-whatsapp-logo"
        slate
        faded
        sm
        @click="$emit('selectContentTemplate')"
      />
      <VideoCallButton
        v-if="
          (isAWebWidgetInbox || isAPIInbox) &&
          !isOnPrivateNote &&
          !isEditorDisabled
        "
        :conversation-id="conversationId"
      />
      <transition name="modal-fade">
        <div
          v-show="uploadRef && uploadRef.dropActive"
          class="flex fixed top-0 right-0 bottom-0 left-0 z-20 flex-col gap-2 justify-center items-center w-full h-full text-n-slate-12 bg-modal-backdrop-light dark:bg-modal-backdrop-dark"
        >
          <fluent-icon icon="cloud-backup" size="40" />
          <h4 class="text-2xl break-words text-n-slate-12">
            {{ $t('CONVERSATION.REPLYBOX.DRAG_DROP') }}
          </h4>
        </div>
      </transition>
      <NextButton
        v-if="enableInsertArticleInReply"
        v-tooltip.top-end="$t('HELP_CENTER.ARTICLE_SEARCH.OPEN_ARTICLE_SEARCH')"
        icon="i-ph-article-ny-times"
        slate
        faded
        sm
        @click="toggleInsertArticle"
      />
    </div>
    <div class="right-wrap">
      <div v-on-clickaway="closeReplyChannelDropdown" class="reply-send-group">
        <NextButton
          :label="sendButtonText"
          type="submit"
          sm
          :color="isNote ? 'amber' : 'blue'"
          :disabled="isSendDisabled"
          class="reply-send-button flex-shrink-0"
          :class="
            showReplyChannelMenu ? 'ltr:rounded-r-none rtl:rounded-l-none' : ''
          "
          @click="onSend"
        />
        <NextButton
          v-if="showReplyChannelMenu"
          v-tooltip.top-end="activeReplyChannelTooltip"
          class="reply-channel-menu__toggle flex-shrink-0 ltr:rounded-l-none rtl:rounded-r-none"
          :aria-label="$t('CONVERSATION.COMMUNICATION_THREAD.REPLY_VIA')"
          :aria-expanded="showReplyChannelDropdown"
          type="button"
          :icon="activeReplyChannelIcon || 'i-lucide-chevron-down'"
          sm
          :color="isNote ? 'amber' : 'blue'"
          @click="toggleReplyChannelDropdown"
        />
        <div
          v-if="showReplyChannelMenu && showReplyChannelDropdown"
          class="reply-channel-menu"
        >
          <button
            v-for="channel in communicationChannels"
            :key="
              channel.channel_key ||
              `${channel.inbox_id}-${channel.conversation_id}`
            "
            type="button"
            class="reply-channel-menu__item"
            :class="{
              'reply-channel-menu__item--active':
                isSelectedReplyChannel(channel),
            }"
            @click="selectReplyChannel(channel)"
          >
            <span
              v-if="replyChannelIcon(channel)"
              :class="replyChannelIcon(channel)"
              class="reply-channel-menu__icon"
            />
            <span class="min-w-0 flex-1 truncate text-left">
              {{ replyChannelLabel(channel) }}
              <span v-if="!channel.can_reply" class="text-n-slate-10">
                {{
                  $t(
                    'CONVERSATION.COMMUNICATION_THREAD.REPLY_RESTRICTED_SUFFIX'
                  )
                }}
              </span>
            </span>
            <span
              v-if="isSelectedReplyChannel(channel)"
              class="i-lucide-check flex-shrink-0 text-n-brand"
            />
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style lang="scss" scoped>
.left-wrap {
  @apply items-center flex gap-2;
}

.right-wrap {
  @apply flex gap-2;
}

.reply-send-group {
  @apply relative flex;
}

.reply-channel-menu {
  @apply absolute bottom-full right-0 z-20 mb-1 min-w-56 rounded-lg border border-n-strong bg-n-alpha-3 p-1 shadow-lg backdrop-blur-[100px];
}

.reply-channel-menu__item {
  @apply flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-sm text-n-slate-12 hover:bg-n-alpha-2 focus-visible:bg-n-alpha-2 focus-visible:outline-none;
}

.reply-channel-menu__item--active {
  @apply bg-n-alpha-2;
}

.reply-channel-menu__icon {
  @apply flex-shrink-0;
}

::v-deep .file-uploads {
  label {
    @apply cursor-pointer;
  }

  &:hover button {
    @apply enabled:bg-n-slate-9/20;
  }
}
</style>
