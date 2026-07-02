<script>
import { defineAsyncComponent } from 'vue';
import { mapGetters } from 'vuex';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useAccount } from 'dashboard/composables/useAccount';
import ChatList from '../../../components/ChatList.vue';
import ConversationBox from '../../../components/widgets/conversation/ConversationBox.vue';
import wootConstants from 'dashboard/constants/globals';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import CmdBarConversationSnooze from 'dashboard/routes/dashboard/commands/CmdBarConversationSnooze.vue';
import { emitter } from 'shared/helpers/mitt';
import SidepanelSwitch from 'dashboard/components-next/Conversation/SidepanelSwitch.vue';
import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';
import {
  buildEffectiveSidebarVisibilitySettings,
  buildSidebarVisibilityState,
  CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
  CONVERSATION_PIPELINES_VISIBILITY_KEY,
} from 'dashboard/components-next/sidebar/sidebarVisibility';

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
    // Clear selected state if navigating away from a conversation to a route without a conversationId to prevent stale data issues
    // and resolves timing issues during navigation with conversation view and other screens
    if (this.conversationId) {
      this.$store.dispatch('clearSelectedState');
    }
    next(); // Continue with navigation
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
  },
  setup() {
    const { uiSettings, updateUISettings } = useUISettings();
    const { accountId, currentAccount } = useAccount();

    return {
      uiSettings,
      updateUISettings,
      accountId,
      currentAccount,
    };
  },
  data() {
    return {
      showSearchModal: false,
    };
  },
  computed: {
    ...mapGetters({
      chatList: 'getAllConversations',
      currentChat: 'getSelectedChat',
    }),
    showConversationList() {
      return this.isOnExpandedLayout ? !this.conversationId : true;
    },
    showMessageView() {
      return this.conversationId ? true : !this.isOnExpandedLayout;
    },
    isOnExpandedLayout() {
      const {
        LAYOUT_TYPES: { CONDENSED },
      } = wootConstants;
      const { conversation_display_type: conversationDisplayType = CONDENSED } =
        this.uiSettings;
      return conversationDisplayType !== CONDENSED;
    },

    effectiveSidebarVisibilitySettings() {
      return buildEffectiveSidebarVisibilitySettings({
        accountId: this.accountId,
        accountSettings: this.currentAccount?.settings || {},
        uiSettings: this.uiSettings,
      });
    },

    shouldShowSidebar() {
      if (!this.currentChat.id) {
        return false;
      }

      const {
        is_contact_sidebar_open: isContactSidebarOpen,
        is_crm_deal_panel_open: isDealsSidebarOpen,
        is_scheduling_appointments_panel_open: isAppointmentsSidebarOpen,
        is_touch_sidebar_open: isTouchSidebarOpen,
      } = this.uiSettings;
      const visibility = buildSidebarVisibilityState(
        this.effectiveSidebarVisibilitySettings
      );

      return (
        isContactSidebarOpen ||
        (isDealsSidebarOpen &&
          visibility[CONVERSATION_PIPELINES_VISIBILITY_KEY]) ||
        (isAppointmentsSidebarOpen &&
          visibility[CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY]) ||
        isTouchSidebarOpen
      );
    },
  },
  watch: {
    conversationId() {
      this.fetchConversationIfUnavailable();
    },
    'currentChat.inbox_id'() {
      this.normalizeConversationRoute();
    },
  },

  created() {
    // Clear selected state early if no conversation is selected
    // This prevents child components from accessing stale data
    // and resolves timing issues during navigation
    // with conversation view and other screens
    if (!this.conversationId) {
      this.$store.dispatch('clearSelectedState');
    }
  },

  mounted() {
    this.$store.dispatch('agents/get');
    this.$store.dispatch('portals/index');
    this.initialize();
    this.$watch('$store.state.route', () => this.initialize());
    this.$watch('chatList.length', () => {
      this.setActiveChat();
    });
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
    fetchConversationIfUnavailable() {
      if (!this.conversationId) {
        return;
      }
      const chat = this.findConversation();
      if (!chat) {
        this.$store.dispatch(
          this.communicationThreadMode
            ? 'getCommunicationThread'
            : 'getConversation',
          this.conversationId
        );
      }
    },
    findConversation() {
      const conversationId = parseInt(this.conversationId, 10);
      return this.chatList.find(
        c =>
          c.id === conversationId &&
          isCommunicationThread(c) === this.communicationThreadMode
      );
    },
    normalizeConversationRoute() {
      if (
        this.communicationThreadMode ||
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
    setActiveChat() {
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
      :communication-thread-mode="communicationThreadMode"
      :is-on-expanded-layout="isOnExpandedLayout"
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
