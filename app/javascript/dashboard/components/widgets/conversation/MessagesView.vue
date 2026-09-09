<script>
import { ref, provide, useTemplateRef } from 'vue';
import { useElementSize } from '@vueuse/core';
// composable
import { useLabelSuggestions } from 'dashboard/composables/useLabelSuggestions';
import { useSnakeCase } from 'dashboard/composables/useTransformKeys';
import { useAlert } from 'dashboard/composables';

// components
import ReplyBox from './ReplyBox.vue';
import MessageList from 'next/message/MessageList.vue';
import ConversationLabelSuggestion from './conversation/LabelSuggestion.vue';
import Banner from 'dashboard/components/ui/Banner.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import ResizableEditorWrapper from './ResizableEditorWrapper.vue';
import IntersectionObserver from 'dashboard/components/IntersectionObserver.vue';

// stores and apis
import { mapGetters } from 'vuex';
import ConversationApi from 'dashboard/api/inbox/conversation';

// mixins
import inboxMixin, { INBOX_FEATURES } from 'shared/mixins/inboxMixin';

// utils
import { emitter } from 'shared/helpers/mitt';
import { getTypingUsersText } from '../../../helper/commons';
import {
  scrollConversationPanelToBottom,
  scrollElementIntoConversationPanel,
} from './helpers/scrollTopCalculationHelper';
import { LocalStorage } from 'shared/helpers/localStorage';
import {
  filterDuplicateSourceMessages,
  getUnreadIncomingMessages,
  isImportedHistoryMessage,
  isPublicIncomingMessage,
} from 'dashboard/helper/conversationHelper';

import {
  getCommunicationThreadTypingTargetIds,
  getCommunicationReplyChannels,
  isCommunicationThread,
} from 'dashboard/helper/communicationThreadHelper';

// constants
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { REPLY_POLICY } from 'shared/constants/links';
import wootConstants from 'dashboard/constants/globals';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';
import { INBOX_TYPES } from 'dashboard/helper/inbox';

export default {
  components: {
    MessageList,
    ReplyBox,
    Banner,
    ConversationLabelSuggestion,
    Spinner,
    Icon,
    ResizableEditorWrapper,
    IntersectionObserver,
  },
  mixins: [inboxMixin],
  setup() {
    const conversationPanelRef = ref(null);
    const resizableEditorWrapperRef = ref(null);
    const messagesViewRef = useTemplateRef('messagesViewRef');
    const topBannerRef = useTemplateRef('topBannerRef');
    const { height: containerHeight } = useElementSize(messagesViewRef);
    const { height: topBannerHeight } = useElementSize(topBannerRef);

    const {
      captainTasksEnabled,
      isLabelSuggestionFeatureEnabled,
      getLabelSuggestions,
    } = useLabelSuggestions();

    provide('contextMenuElementTarget', conversationPanelRef);

    return {
      captainTasksEnabled,
      getLabelSuggestions,
      isLabelSuggestionFeatureEnabled,
      conversationPanelRef,
      resizableEditorWrapperRef,
      messagesViewRef,
      topBannerRef,
      containerHeight,
      topBannerHeight,
    };
  },
  data() {
    return {
      isLoadingPrevious: true,
      heightBeforeLoad: null,
      conversationPanel: null,
      hasUserScrolled: false,
      isProgrammaticScroll: false,
      messageSentSinceOpened: false,
      labelSuggestions: [],
      isCancellingCaptainResponse: false,
      conversationHistoryGeneration: 0,
    };
  },

  computed: {
    ...mapGetters({
      currentChat: 'getSelectedChat',
      currentUserId: 'getCurrentUserID',
      listLoadingStatus: 'getAllMessagesLoaded',
      currentAccountId: 'getCurrentAccountId',
    }),
    isOpen() {
      return this.currentChat?.status === wootConstants.STATUS_TYPE.OPEN;
    },
    shouldShowLabelSuggestions() {
      return (
        this.isOpen &&
        this.captainTasksEnabled &&
        this.isLabelSuggestionFeatureEnabled &&
        !this.messageSentSinceOpened
      );
    },
    inboxId() {
      return this.currentChat.inbox_id;
    },
    inbox() {
      return this.$store.getters['inboxes/getInbox'](this.inboxId);
    },
    typingUsersList() {
      const getTypingUsers =
        this.$store.getters['conversationTypingStatus/getUserList'];
      const userByKey = new Map();
      getCommunicationThreadTypingTargetIds(this.currentChat).forEach(id => {
        getTypingUsers(id).forEach(user => {
          userByKey.set(`${user.type}:${user.id}`, user);
        });
      });
      return [...userByKey.values()];
    },
    isAnyoneTyping() {
      const userList = this.typingUsersList;
      return userList.length !== 0;
    },
    isCaptainAssistantTyping() {
      return this.typingUsersList.some(
        user => user.type === 'captain_assistant'
      );
    },
    typingUserNames() {
      const userList = this.typingUsersList;
      if (this.isAnyoneTyping) {
        const [i18nKey, params] = getTypingUsersText(userList);
        return this.$t(i18nKey, params);
      }

      return '';
    },
    getMessages() {
      const messages = this.currentChat.messages || [];
      if (this.isAWhatsAppChannel) {
        return filterDuplicateSourceMessages(messages);
      }
      return messages;
    },
    unReadMessages() {
      const unreadCandidates = this.getMessages.filter(
        message => !this.isImportedHistoryMessage(message)
      );
      if (!isCommunicationThread(this.currentChat)) {
        return getUnreadIncomingMessages(
          unreadCandidates,
          this.currentChat.agent_last_seen_at
        );
      }

      return unreadCandidates.filter(message =>
        this.isUnreadCommunicationThreadMessage(message)
      );
    },
    unreadMessageIds() {
      return this.unReadMessages.map(message => message.id);
    },
    communicationThreadLastSeenByConversationId() {
      return new Map(
        (this.currentChat?.channels || []).map(channel => [
          String(channel.conversation_id),
          channel.agent_last_seen_at || 0,
        ])
      );
    },
    shouldShowSpinner() {
      return (
        (this.currentChat && this.currentChat.dataFetched === undefined) ||
        (!this.listLoadingStatus && this.isLoadingPrevious)
      );
    },
    canObservePreviousMessages() {
      return Boolean(
        this.conversationPanel &&
          this.currentChat?.dataFetched === true &&
          this.currentChat?.messages?.length &&
          !this.listLoadingStatus
      );
    },
    previousMessagesObserverOptions() {
      return {
        root: this.conversationPanel,
        rootMargin: '100px 0px 0px 0px',
      };
    },
    // Check there is a instagram inbox exists with the same instagram_id
    hasDuplicateInstagramInbox() {
      const instagramId = this.inbox.instagram_id;
      const { additional_attributes: additionalAttributes = {} } = this.inbox;
      const instagramInbox =
        this.$store.getters['inboxes/getInstagramInboxByInstagramId'](
          instagramId
        );

      return (
        this.inbox.channel_type === INBOX_TYPES.FB &&
        additionalAttributes.type === 'instagram_direct_message' &&
        instagramInbox
      );
    },

    replyWindowBannerMessage() {
      if (this.isAWhatsAppChannel) {
        return this.$t('CONVERSATION.TWILIO_WHATSAPP_CAN_REPLY');
      }
      if (this.isAPIInbox) {
        const { additional_attributes: additionalAttributes = {} } = this.inbox;
        if (additionalAttributes) {
          const {
            agent_reply_time_window_message: agentReplyTimeWindowMessage,
            agent_reply_time_window: agentReplyTimeWindow,
          } = additionalAttributes;
          return (
            agentReplyTimeWindowMessage ||
            this.$t('CONVERSATION.API_HOURS_WINDOW', {
              hours: agentReplyTimeWindow,
            })
          );
        }
        return '';
      }
      return this.$t('CONVERSATION.CANNOT_REPLY');
    },
    replyWindowLink() {
      if (this.isAFacebookInbox || this.isAnInstagramChannel) {
        return REPLY_POLICY.FACEBOOK;
      }
      if (this.isAWhatsAppCloudChannel) {
        return REPLY_POLICY.WHATSAPP_CLOUD;
      }
      if (this.isATiktokChannel) {
        return REPLY_POLICY.TIKTOK;
      }
      if (!this.isAPIInbox) {
        return REPLY_POLICY.TWILIO_WHATSAPP;
      }
      return '';
    },
    replyWindowLinkText() {
      if (
        this.isAWhatsAppChannel ||
        this.isAFacebookInbox ||
        this.isAnInstagramChannel
      ) {
        return this.$t('CONVERSATION.24_HOURS_WINDOW');
      }
      if (this.isATiktokChannel) {
        return this.$t('CONVERSATION.48_HOURS_WINDOW');
      }
      if (!this.isAPIInbox) {
        return this.$t('CONVERSATION.TWILIO_WHATSAPP_24_HOURS_WINDOW');
      }
      return '';
    },
    unreadMessageCount() {
      return this.currentChat.unread_count || 0;
    },
    unreadMessageLabel() {
      const count =
        this.unreadMessageCount > 99 ? '99+' : this.unreadMessageCount;
      const label =
        this.unreadMessageCount > 1
          ? 'CONVERSATION.UNREAD_MESSAGES'
          : 'CONVERSATION.UNREAD_MESSAGE';
      return `${count} ${this.$t(label)}`;
    },
    hasCommunicationThreadReplyableChannel() {
      if (!isCommunicationThread(this.currentChat)) return false;

      return (
        getCommunicationReplyChannels(this.currentChat?.channels || []).length >
        0
      );
    },
    shouldShowReplyWindowBanner() {
      return (
        !this.currentChat?.can_reply &&
        !this.isAVoiceChannel &&
        !this.hasCommunicationThreadReplyableChannel
      );
    },
    inboxSupportsReplyTo() {
      const incoming = this.inboxHasFeature(INBOX_FEATURES.REPLY_TO);
      const outgoing =
        this.inboxHasFeature(INBOX_FEATURES.REPLY_TO_OUTGOING) &&
        !this.is360DialogWhatsAppChannel;

      return { incoming, outgoing };
    },
  },

  watch: {
    currentChat(newChat, oldChat) {
      if (
        newChat.id === oldChat.id &&
        isCommunicationThread(newChat) === isCommunicationThread(oldChat)
      ) {
        return;
      }
      this.conversationHistoryGeneration += 1;
      this.hasUserScrolled = false;
      this.fetchAllAttachmentsFromCurrentChat();
      this.fetchSuggestions();
      this.messageSentSinceOpened = false;
      this.resetReplyEditorHeight();
    },
  },

  created() {
    emitter.on(BUS_EVENTS.SCROLL_TO_MESSAGE, this.onScrollToMessage);
    // when a message is sent we set the flag to true this hides the label suggestions,
    // until the chat is changed and the flag is reset in the watch for currentChat
    emitter.on(BUS_EVENTS.MESSAGE_SENT, () => {
      this.messageSentSinceOpened = true;
    });
  },

  mounted() {
    this.addScrollListener();
    this.fetchAllAttachmentsFromCurrentChat();
    this.fetchSuggestions();
  },

  unmounted() {
    this.conversationHistoryGeneration += 1;
    this.removeBusListeners();
    this.removeScrollListener();
  },

  methods: {
    async fetchSuggestions() {
      // start empty, this ensures that the label suggestions are not shown
      this.labelSuggestions = [];

      if (this.isLabelSuggestionDismissed()) {
        return;
      }

      // Early exit if conversation already has labels - no need to suggest more
      const existingLabels = this.currentChat?.labels || [];
      if (existingLabels.length > 0) return;

      if (!this.captainTasksEnabled || !this.isLabelSuggestionFeatureEnabled) {
        return;
      }

      this.labelSuggestions = await this.getLabelSuggestions();

      // once the labels are fetched, we need to scroll to bottom
      // but we need to wait for the DOM to be updated
      // so we use the nextTick method
      this.$nextTick(() => {
        // this param is added to route, telling the UI to navigate to the message
        // it is triggered by the SCROLL_TO_MESSAGE method
        // see setActiveChat on ConversationView.vue for more info
        const { messageId } = this.$route.query;

        // only trigger the scroll to bottom if the user has not scrolled
        // and there's no active messageId that is selected in view
        if (!messageId && !this.hasUserScrolled) {
          this.scrollToBottom();
        }
      });
    },
    isLabelSuggestionDismissed() {
      return LocalStorage.getFlag(
        LOCAL_STORAGE_KEYS.DISMISSED_LABEL_SUGGESTIONS,
        this.currentAccountId,
        this.currentChat.id
      );
    },
    fetchAllAttachmentsFromCurrentChat() {
      this.$store.dispatch('fetchAllAttachments', {
        conversationId: this.currentChat.id,
        isCommunicationThread: Boolean(
          this.currentChat.is_communication_thread
        ),
      });
    },
    removeBusListeners() {
      emitter.off(BUS_EVENTS.SCROLL_TO_MESSAGE, this.onScrollToMessage);
    },
    onScrollToMessage({ messageId = '', force = false } = {}) {
      this.$nextTick(() => {
        const hasExplicitMessageTarget = Boolean(messageId);
        const messageElement = hasExplicitMessageTarget
          ? document.getElementById('message' + messageId)
          : null;
        if (messageElement) {
          this.isProgrammaticScroll = true;
          messageElement.scrollIntoView({ behavior: 'smooth' });
          this.fetchPreviousMessages();
          this.makeMessagesRead();
        } else if (
          force ||
          (!hasExplicitMessageTarget &&
            (!this.hasUserScrolled || this.isNearConversationBottom()))
        ) {
          this.scrollToBottom();
          this.makeMessagesRead();
        }
      });
    },
    addScrollListener() {
      this.conversationPanel = this.$el.querySelector('.conversation-panel');
      this.setScrollParams();
      this.conversationPanel.addEventListener('scroll', this.handleScroll);
      this.$nextTick(() => this.scrollToBottom());
      this.isLoadingPrevious = false;
    },
    removeScrollListener() {
      this.conversationPanel.removeEventListener('scroll', this.handleScroll);
    },
    scrollToBottom() {
      if (!this.conversationPanel) return false;

      this.isProgrammaticScroll = true;

      // Unread messages have the highest priority: scroll to the first
      // concrete unread DOM node instead of estimating its position from the
      // total unread height. This keeps imported/backfilled channels, date
      // dividers, attachments, call cards, and channel dividers from shifting
      // the viewport to the wrong part of the timeline.
      if (this.unreadMessageCount > 0) {
        const firstUnreadMessage =
          this.conversationPanel.querySelector('.message--unread');

        if (firstUnreadMessage) {
          return scrollElementIntoConversationPanel(
            this.conversationPanel,
            firstUnreadMessage,
            { block: 'start' }
          );
        }

        // A stale aggregate can outlive its unread message. Keep the viewport
        // at the newest mounted content; the caller still sends mark-read so
        // the backend can reconcile the aggregate instead of deadlocking here.
        scrollConversationPanelToBottom(this.conversationPanel);
        return false;
      }

      const labelSuggestions =
        this.conversationPanel.querySelector('.label-suggestion');
      if (labelSuggestions) {
        return scrollElementIntoConversationPanel(
          this.conversationPanel,
          labelSuggestions,
          { block: 'end' }
        );
      }

      return scrollConversationPanelToBottom(this.conversationPanel);
    },
    communicationThreadMessageLastSeenAt(message) {
      const conversationId = String(message?.conversation_id);
      if (
        this.communicationThreadLastSeenByConversationId.has(conversationId)
      ) {
        return this.communicationThreadLastSeenByConversationId.get(
          conversationId
        );
      }

      return this.currentChat.agent_last_seen_at || 0;
    },
    isImportedHistoryMessage,
    isUnreadCommunicationThreadMessage(message) {
      if (!isPublicIncomingMessage(message)) return false;

      return (
        Number(message.created_at || 0) * 1000 >
        Number(this.communicationThreadMessageLastSeenAt(message) || 0) * 1000
      );
    },
    isNearConversationBottom(offset = 80) {
      if (!this.conversationPanel) return true;

      const distanceFromBottom =
        this.conversationPanel.scrollHeight -
        (this.conversationPanel.scrollTop +
          this.conversationPanel.clientHeight);
      return distanceFromBottom <= offset;
    },
    setScrollParams() {
      this.heightBeforeLoad = this.conversationPanel.scrollHeight;
      this.scrollTopBeforeLoad = this.conversationPanel.scrollTop;
    },

    async fetchPreviousMessages(scrollTop = 0) {
      const oldestMessage = this.currentChat.messages?.[0];
      const shouldLoadMoreMessages =
        this.currentChat.dataFetched === true &&
        Boolean(oldestMessage) &&
        !this.listLoadingStatus &&
        !this.isLoadingPrevious;

      if (scrollTop >= 100 || !shouldLoadMoreMessages) return;

      this.setScrollParams();
      const conversationPanel = this.conversationPanel;
      const conversationId = this.currentChat.id;
      const historyGeneration = this.conversationHistoryGeneration;
      const loadedConversationIsThread = isCommunicationThread(
        this.currentChat
      );
      const isCurrentConversation = () =>
        this.conversationHistoryGeneration === historyGeneration &&
        this.conversationPanel === conversationPanel &&
        String(this.currentChat?.id) === String(conversationId) &&
        isCommunicationThread(this.currentChat) === loadedConversationIsThread;
      let shouldLoadPreviousMessagesAgain = false;

      if (scrollTop < 100) {
        this.isLoadingPrevious = true;
        try {
          await this.$store.dispatch('fetchPreviousMessages', {
            conversationId,
            before: oldestMessage.id,
          });
          if (!isCurrentConversation()) return;

          await new Promise(resolve => {
            this.$nextTick(() => {
              if (!isCurrentConversation()) {
                resolve();
                return;
              }

              const heightDifference =
                conversationPanel.scrollHeight - this.heightBeforeLoad;
              conversationPanel.scrollTop =
                this.scrollTopBeforeLoad + heightDifference;
              this.setScrollParams();
              shouldLoadPreviousMessagesAgain =
                this.currentChat.messages?.[0]?.id !== oldestMessage.id &&
                !this.listLoadingStatus &&
                this.conversationPanel.scrollHeight <=
                  this.conversationPanel.clientHeight;
              resolve();
            });
          });
        } catch (error) {
          // Ignore Error
        } finally {
          this.isLoadingPrevious = false;
        }

        if (shouldLoadPreviousMessagesAgain && isCurrentConversation()) {
          await this.fetchPreviousMessages(conversationPanel.scrollTop);
        }
      }
    },

    handleScroll(e) {
      if (this.isProgrammaticScroll) {
        // Reset the flag
        this.isProgrammaticScroll = false;
        this.hasUserScrolled = false;
      } else {
        this.hasUserScrolled = true;
      }
      emitter.emit(BUS_EVENTS.ON_MESSAGE_LIST_SCROLL);
      this.fetchPreviousMessages(e.target.scrollTop);
    },

    makeMessagesRead() {
      if (this.currentChat?.is_communication_thread) {
        this.$store.dispatch('markCommunicationThreadRead', {
          id: this.currentChat.id,
        });
        return;
      }

      this.$store.dispatch('markMessagesRead', { id: this.currentChat.id });
    },
    async handleMessageRetry(message) {
      if (!message) return;
      const payload = useSnakeCase(message);
      await this.$store.dispatch('sendMessageWithData', payload);
    },
    async cancelCaptainResponse() {
      if (this.isCancellingCaptainResponse || !this.currentChat?.id) return;

      this.isCancellingCaptainResponse = true;
      try {
        await ConversationApi.cancelCaptainResponse({
          conversationId: this.currentChat.id,
        });
      } catch (error) {
        useAlert(this.$t('CONVERSATION.CAPTAIN_RESPONSE_CANCEL_FAILED'));
      } finally {
        this.isCancellingCaptainResponse = false;
      }
    },
    toggleReplyEditorSize() {
      this.resizableEditorWrapperRef?.toggleEditorExpand?.();
    },
    resetReplyEditorHeight() {
      this.resizableEditorWrapperRef?.resetEditorHeight?.();
    },
  },
};
</script>

<template>
  <div
    ref="messagesViewRef"
    class="flex flex-col justify-between flex-grow h-full min-w-0 m-0"
  >
    <div ref="topBannerRef">
      <Banner
        v-if="shouldShowReplyWindowBanner"
        color-scheme="alert"
        class="mx-2 mt-2 overflow-hidden rounded-lg"
        :banner-message="replyWindowBannerMessage"
        :href-link="replyWindowLink"
        :href-link-text="replyWindowLinkText"
      />
      <Banner
        v-else-if="hasDuplicateInstagramInbox"
        color-scheme="alert"
        class="mx-2 mt-2 overflow-hidden rounded-lg"
        :banner-message="$t('CONVERSATION.OLD_INSTAGRAM_INBOX_REPLY_BANNER')"
      />
    </div>
    <MessageList
      ref="conversationPanelRef"
      class="conversation-panel flex-shrink flex-grow basis-px flex flex-col overflow-y-auto relative h-full m-0 pb-4"
      :current-user-id="currentUserId"
      :first-unread-id="unReadMessages[0]?.id"
      :is-an-email-channel="isAnEmailChannel"
      :inbox-supports-reply-to="inboxSupportsReplyTo"
      :messages="getMessages"
      :unread-message-ids="unreadMessageIds"
      @retry="handleMessageRetry"
    >
      <template #beforeAll>
        <transition name="slide-up">
          <!-- eslint-disable-next-line vue/require-toggle-inside-transition -->
          <li
            class="min-h-[4rem] flex flex-shrink-0 flex-grow-0 items-center flex-auto justify-center max-w-full mt-0 mr-0 mb-1 ml-0 relative first:mt-auto last:mb-0"
          >
            <IntersectionObserver
              v-if="canObservePreviousMessages"
              :options="previousMessagesObserverOptions"
              @observed="fetchPreviousMessages"
            />
            <Spinner v-if="shouldShowSpinner" class="text-n-brand" />
          </li>
        </transition>
      </template>
      <template #unreadBadge>
        <li
          v-show="unreadMessageCount != 0"
          class="list-none flex justify-center items-center"
        >
          <span
            class="shadow-lg rounded-full bg-n-ruby-9 text-white text-xs font-medium my-2.5 mx-auto px-2.5 py-1.5"
          >
            {{ unreadMessageLabel }}
          </span>
        </li>
      </template>
      <template #after>
        <ConversationLabelSuggestion
          v-if="shouldShowLabelSuggestions"
          :suggested-labels="labelSuggestions"
          :chat-labels="currentChat.labels"
          :conversation-id="currentChat.id"
        />
      </template>
    </MessageList>
    <div class="flex relative flex-col bg-n-surface-1">
      <div
        v-if="isAnyoneTyping"
        class="absolute z-10 flex items-center w-full h-0 -top-8"
      >
        <div
          class="flex items-center py-2 pr-3 pl-5 shadow-md rounded-full bg-n-solid-1 border border-n-weak text-n-slate-12 text-xs font-semibold my-2.5 mx-auto"
        >
          {{ typingUserNames }}
          <img
            class="h-4 w-6 object-contain ltr:ml-2 rtl:mr-2"
            src="assets/images/typing.gif"
            alt="Someone is typing"
          />
          <button
            v-if="isCaptainAssistantTyping"
            type="button"
            class="inline-flex items-center justify-center flex-shrink-0 rounded-full bg-n-alpha-2 text-n-slate-11 hover:bg-n-alpha-3 hover:text-n-slate-12 disabled:opacity-50 disabled:cursor-not-allowed ltr:ml-2 rtl:mr-2 size-8"
            :title="$t('CONVERSATION.CAPTAIN_RESPONSE_CANCEL')"
            :aria-label="$t('CONVERSATION.CAPTAIN_RESPONSE_CANCEL')"
            :disabled="isCancellingCaptainResponse"
            @click="cancelCaptainResponse"
          >
            <Icon icon="i-ph-stop-fill" class="size-[1.375rem] text-current" />
          </button>
        </div>
      </div>
      <ResizableEditorWrapper
        ref="resizableEditorWrapperRef"
        :container-height="Math.max(0, containerHeight - topBannerHeight)"
      >
        <ReplyBox @toggle-editor-size="toggleReplyEditorSize" />
      </ResizableEditorWrapper>
    </div>
  </div>
</template>
