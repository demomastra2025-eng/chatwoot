<script>
import { defineAsyncComponent } from 'vue';
import { mapGetters } from 'vuex';
import { useUISettings } from 'dashboard/composables/useUISettings';
import {
  resetMobileConversationPanel,
  useConversationSidepanelAvailability,
} from 'dashboard/composables/useConversationSidepanelAvailability';
import ChatList from '../../../components/ChatList.vue';
import ConversationBox from '../../../components/widgets/conversation/ConversationBox.vue';
import wootConstants from 'dashboard/constants/globals';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import CmdBarConversationSnooze from 'dashboard/routes/dashboard/commands/CmdBarConversationSnooze.vue';
import { emitter } from 'shared/helpers/mitt';
import SidepanelSwitch from 'dashboard/components-next/Conversation/SidepanelSwitch.vue';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import {
  THREAD_CAPABLE_CONVERSATION_ROUTES,
  isCommunicationThread,
  isDraftDialog,
} from 'dashboard/helper/communicationThreadHelper';
import { useAlert } from 'dashboard/composables';

const ConversationSidebar = defineAsyncComponent(
  () =>
    import('dashboard/components/widgets/conversation/ConversationSidebar.vue')
);

export default {
  components: {
    ChatList,
    ConversationBox,
    CmdBarConversationSnooze,
    SidepanelSwitch,
    ConversationSidebar,
  },
  beforeRouteLeave(to, from, next) {
    // Mark route leave in-flight so background route normalization does not
    // cancel the outgoing navigation; actual selected chat cleanup happens in
    // beforeUnmount so the current conversation pane does not blank out while
    // lazy route chunks are still loading.
    this.isLeavingConversationRoute = true;
    next();
  },
  beforeRouteUpdate(to, from, next) {
    if (to.path !== from.path) resetMobileConversationPanel();
    next();
  },
  props: {
    inboxId: {
      type: [String, Number],
      default: 0,
    },
    conversationId: {
      type: [String, Number],
      default: 0,
    },
    label: {
      type: String,
      default: '',
    },
    teamId: {
      type: String,
      default: '',
    },
    conversationType: {
      type: String,
      default: '',
    },
    foldersId: {
      type: [String, Number],
      default: 0,
    },
    communicationThreadMode: {
      type: Boolean,
      default: false,
    },
    // The dialog of a person opened by the person (the contact card, a calendar entry): the person's thread when they have one,
    // else the empty screen of a draft.
    personContactId: {
      type: [String, Number],
      default: '',
    },
  },
  setup() {
    const { uiSettings, updateUISettings } = useUISettings();
    const { activePanel } = useConversationSidepanelAvailability();

    return {
      uiSettings,
      updateUISettings,
      activePanel,
    };
  },
  data() {
    return {
      showSearchModal: false,
      isLeavingConversationRoute: false,
    };
  },
  computed: {
    ...mapGetters({
      chatList: 'getAllConversations',
      currentChat: 'getSelectedChat',
    }),
    effectiveCommunicationThreadMode() {
      if (this.communicationThreadMode) return true;
      if (!THREAD_CAPABLE_CONVERSATION_ROUTES.includes(this.$route?.name)) {
        return false;
      }
      return Boolean(
        this.$store?.getters?.['accounts/isFeatureEnabledonAccount']?.(
          this.$route?.params?.accountId,
          FEATURE_FLAGS.COMMUNICATION_THREADS
        )
      );
    },
    hasSelectedDialog() {
      return Boolean(this.conversationId || this.personContactId);
    },
    showConversationList() {
      return this.isOnExpandedLayout
        ? !(this.conversationId || this.personContactId)
        : true;
    },
    showMessageView() {
      return this.conversationId || this.personContactId
        ? true
        : !this.isOnExpandedLayout;
    },
    isOnExpandedLayout() {
      const {
        LAYOUT_TYPES: { CONDENSED },
      } = wootConstants;
      const { conversation_display_type: conversationDisplayType = CONDENSED } =
        this.uiSettings;
      return conversationDisplayType !== CONDENSED;
    },

    shouldShowSidebar() {
      if (!this.currentChat.id) {
        return false;
      }

      return Boolean(this.activePanel);
    },
  },
  watch: {
    conversationId() {
      resetMobileConversationPanel();
      this.fetchConversationIfUnavailable();
    },
    effectiveCommunicationThreadMode(nextMode, previousMode) {
      if (nextMode === previousMode || !this.conversationId) return;
      this.fetchConversationIfUnavailable();
      this.setActiveChat();
    },
    'currentChat.inbox_id'() {
      this.normalizeConversationRoute();
    },
    // The first message (or call, or note) of an empty dialog made the thread: the address of the screen becomes the thread's.
    'currentChat.id'() {
      this.replaceRouteWithPromotedThread();
    },
    personContactId() {
      this.setActiveChat();
    },
  },

  created() {
    resetMobileConversationPanel();
    // Clear selected state early if no conversation is selected
    // This prevents child components from accessing stale data
    // and resolves timing issues during navigation
    // with conversation view and other screens
    if (!this.hasSelectedDialog) {
      this.$store.dispatch('clearSelectedState');
    } else if (this.personContactId && !this.isChatOfPerson(this.currentChat)) {
      // Another chat must not show while the dialog of this person is being opened.
      this.$store.dispatch('clearSelectedState');
    }
  },

  mounted() {
    if (
      !this.$store.getters['agents/getAgents']?.length &&
      !this.$store.getters['agents/getUIFlags']?.isFetching
    ) {
      this.$store.dispatch('agents/get');
    }
    this.initialize();
    this.$watch('$store.state.route', () => {
      this.isLeavingConversationRoute = false;
      this.initialize();
    });
    this.$watch('chatList.length', () => {
      this.setActiveChat();
    });
  },

  beforeUnmount() {
    resetMobileConversationPanel();
    this.isLeavingConversationRoute = true;
    if (this.hasSelectedDialog || this.currentChat?.id) {
      this.$store.dispatch('clearSelectedState');
    }
  },

  methods: {
    onConversationLoad() {
      this.fetchConversationIfUnavailable();
    },
    initialize() {
      this.$store.dispatch('setActiveInbox', this.inboxId);
      this.setActiveChat();
    },
    toggleConversationLayout() {
      const { LAYOUT_TYPES } = wootConstants;
      const {
        conversation_display_type:
          conversationDisplayType = LAYOUT_TYPES.CONDENSED,
      } = this.uiSettings;
      const newViewType =
        conversationDisplayType === LAYOUT_TYPES.CONDENSED
          ? LAYOUT_TYPES.EXPANDED
          : LAYOUT_TYPES.CONDENSED;
      this.updateUISettings({
        conversation_display_type: newViewType,
        previously_used_conversation_display_type: newViewType,
      });
    },
    isThreadMode() {
      return Boolean(
        this.effectiveCommunicationThreadMode ?? this.communicationThreadMode
      );
    },
    fetchConversationIfUnavailable() {
      if (!this.conversationId) {
        return;
      }
      const chat = this.findConversation();
      if (!chat) {
        this.$store.dispatch(
          this.isThreadMode() ? 'getCommunicationThread' : 'getConversation',
          this.conversationId
        );
      }
    },
    findConversation() {
      const conversationId = parseInt(this.conversationId, 10);
      const threadMode = this.isThreadMode();
      return this.chatList.find(
        c => c.id === conversationId && isCommunicationThread(c) === threadMode
      );
    },
    normalizeConversationRoute() {
      if (
        this.isLeavingConversationRoute ||
        this.isThreadMode() ||
        this.$route.name !== 'inbox_conversation' ||
        !this.conversationId ||
        !this.currentChat?.inbox_id
      ) {
        return;
      }

      this.$router.replace({
        name: 'conversation_through_inbox',
        params: {
          ...this.$route.params,
          inbox_id: this.currentChat.inbox_id,
          conversation_id: this.currentChat.id || this.conversationId,
        },
        query: this.$route.query,
        hash: this.$route.hash,
      });
    },
    async openPersonDialog() {
      const contactId = this.personContactId;
      // This person's dialog is already the open chat: do not read it again, that would drop the bubbles that failed to send.
      if (isDraftDialog(this.currentChat)) {
        if (this.isChatOfPerson(this.currentChat)) return;
      } else if (this.isOpenThreadOfPerson(this.currentChat)) {
        this.replaceRouteWithPromotedThread();
        return;
      }

      try {
        const result = await this.$store.dispatch('openPersonDialog', {
          contactId,
        });
        if (!result || String(this.personContactId) !== String(contactId)) {
          return;
        }
        if (result.communicationThreadId) {
          this.$router.replace({
            name: 'communication_thread_conversation',
            params: {
              accountId: this.$route.params.accountId,
              communication_thread_id: result.communicationThreadId,
            },
            query: this.$route.query,
          });
        }
      } catch (error) {
        useAlert(this.$t('PERSON_DIALOG.OPEN_ERROR'));
      }
    },
    isChatOfPerson(chat) {
      if (isDraftDialog(chat)) {
        return String(chat.person_contact_id) === String(this.personContactId);
      }
      return this.isOpenThreadOfPerson(chat);
    },
    isOpenThreadOfPerson(chat) {
      if (!chat?.id || isDraftDialog(chat) || !isCommunicationThread(chat)) {
        return false;
      }

      return (
        String(chat.contact_id ?? chat.meta?.sender?.id) ===
        String(this.personContactId)
      );
    },
    replaceRouteWithPromotedThread() {
      if (
        !this.personContactId ||
        !this.isOpenThreadOfPerson(this.currentChat)
      ) {
        return;
      }

      this.$router.replace({
        name: 'communication_thread_conversation',
        params: {
          accountId: this.$route.params.accountId,
          communication_thread_id: this.currentChat.id,
        },
        query: this.$route.query,
      });
    },
    setActiveChat() {
      if (this.personContactId) {
        this.openPersonDialog();
        return;
      }
      if (this.conversationId) {
        const selectedConversation = this.findConversation();
        // If conversation doesn't exist or selected conversation is same as the active
        // conversation, don't set active conversation.
        if (!selectedConversation) {
          return;
        }
        const isSameActiveChat =
          String(selectedConversation.id) === String(this.currentChat.id) &&
          isCommunicationThread(selectedConversation) ===
            isCommunicationThread(this.currentChat);
        if (isSameActiveChat) {
          const { messageId } = this.$route.query;
          emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE, { messageId });
          return;
        }
        const { messageId } = this.$route.query;
        this.$store
          .dispatch('setActiveChat', {
            data: selectedConversation,
            after: messageId,
          })
          .then(() => {
            this.normalizeConversationRoute();
            emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE, { messageId });
          });
      } else {
        this.$store.dispatch('clearSelectedState');
      }
    },
    onSearch() {
      this.showSearchModal = true;
    },
    closeSearch() {
      this.showSearchModal = false;
    },
  },
};
</script>

<template>
  <section class="flex w-full h-full min-w-0">
    <ChatList
      :show-conversation-list="showConversationList"
      :conversation-inbox="inboxId"
      :label="label"
      :team-id="teamId"
      :conversation-type="conversationType"
      :folders-id="foldersId"
      :communication-thread-mode="effectiveCommunicationThreadMode"
      :is-on-expanded-layout="isOnExpandedLayout"
      :is-leaving-route="isLeavingConversationRoute"
      @conversation-load="onConversationLoad"
    />
    <ConversationBox
      v-if="showMessageView"
      :inbox-id="inboxId"
      :is-on-expanded-layout="isOnExpandedLayout"
    >
      <SidepanelSwitch v-if="currentChat.id" />
    </ConversationBox>
    <ConversationSidebar v-if="shouldShowSidebar" :current-chat="currentChat" />
    <CmdBarConversationSnooze />
  </section>
</template>
