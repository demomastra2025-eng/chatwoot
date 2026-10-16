<script>
import { defineAsyncComponent } from 'vue';
import { useAlert } from 'dashboard/composables';
import { mapGetters } from 'vuex';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import ContextMenu from 'dashboard/components/ui/ContextMenu.vue';
import AddCannedModal from 'dashboard/routes/dashboard/settings/canned/AddCanned.vue';
import { useSnakeCase } from 'dashboard/composables/useTransformKeys';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import { conversationUrl, frontendURL } from '../../../helper/URLHelper';
import {
  ACCOUNT_EVENTS,
  CONVERSATION_EVENTS,
} from '../../../helper/AnalyticsHelper/events';
import MenuItem from '../../../components/widgets/conversation/contextMenu/menuItem.vue';
import { useTrack } from 'dashboard/composables';
import NextButton from 'dashboard/components-next/button/Button.vue';
import AppleEmoji from 'shared/components/emoji/AppleEmoji.vue';
import {
  getQuickReactions,
  recordReactionUsage,
} from 'shared/helpers/emojiUsage';
import { getCurrentUserReactionEmoji } from 'dashboard/components-next/message/helpers/messageReactions';

const EmojiInput = defineAsyncComponent(
  () => import('shared/components/emoji/EmojiInput.vue')
);

export default {
  components: {
    AddCannedModal,
    AppleEmoji,
    EmojiInput,
    MenuItem,
    ContextMenu,
    NextButton,
  },
  props: {
    message: {
      type: Object,
      required: true,
    },
    isOpen: {
      type: Boolean,
      default: false,
    },
    enabledOptions: {
      type: Object,
      default: () => ({}),
    },
    contextMenuPosition: {
      type: Object,
      default: () => ({}),
    },
    hideButton: {
      type: Boolean,
      default: false,
    },
  },
  emits: ['open', 'close', 'replyTo', 'edit'],
  setup() {
    const { getPlainText } = useMessageFormatter();

    return {
      getPlainText,
    };
  },
  data() {
    return {
      isCannedResponseModalOpen: false,
      showDeleteModal: false,
      showReactionPicker: false,
      isSubmittingReaction: false,
    };
  },
  computed: {
    ...mapGetters({
      getAccount: 'accounts/getAccount',
      currentAccountId: 'getCurrentAccountId',
      getUISettings: 'getUISettings',
      storeCurrentUserId: 'getCurrentUserID',
    }),
    plainTextContent() {
      return this.getPlainText(this.messageContent);
    },
    conversationId() {
      return this.message.conversation_id ?? this.message.conversationId;
    },
    messageId() {
      return this.message.id;
    },
    messageContent() {
      return this.message.content;
    },
    contentAttributes() {
      return useSnakeCase(
        this.message.content_attributes ?? this.message.contentAttributes
      );
    },
    currentUserId() {
      return (
        this.message.currentUserId ??
        this.message.current_user_id ??
        this.storeCurrentUserId
      );
    },
    currentUserReactionEmoji() {
      return getCurrentUserReactionEmoji(
        this.message.content_attributes ?? this.message.contentAttributes,
        this.currentUserId
      );
    },
    quickReactions() {
      const base = getQuickReactions(6);
      const active = this.currentUserReactionEmoji;
      if (active && !base.includes(active)) {
        return [active, ...base.slice(0, 5)];
      }
      return base;
    },
  },
  watch: {
    isOpen(newVal) {
      if (!newVal) {
        this.showReactionPicker = false;
      }
    },
  },
  methods: {
    async copyLinkToMessage() {
      const fullConversationURL =
        window.chatwootConfig.hostURL +
        frontendURL(
          conversationUrl({
            id: this.conversationId,
            accountId: this.currentAccountId,
            activeInbox: this.message.inbox_id || this.message.inboxId,
          })
        );
      await copyTextToClipboard(
        `${fullConversationURL}?messageId=${this.messageId}`
      );
      useAlert(this.$t('CONVERSATION.CONTEXT_MENU.LINK_COPIED'));
      this.handleClose();
    },
    async handleCopy() {
      await copyTextToClipboard(this.plainTextContent);
      useAlert(this.$t('CONTACT_PANEL.COPY_SUCCESSFUL'));
      this.handleClose();
    },
    showCannedResponseModal() {
      useTrack(ACCOUNT_EVENTS.ADDED_TO_CANNED_RESPONSE);
      this.isCannedResponseModalOpen = true;
    },
    hideCannedResponseModal() {
      this.isCannedResponseModalOpen = false;
      this.handleClose();
    },
    handleOpen(e) {
      this.$emit('open', e);
    },
    handleClose(e) {
      this.showReactionPicker = false;
      this.$emit('close', e);
    },
    toggleReactionPicker() {
      this.showReactionPicker = !this.showReactionPicker;
    },
    async handleQuickReaction(emoji) {
      if (!emoji || this.isSubmittingReaction) return;

      this.isSubmittingReaction = true;
      const isRemoving = this.currentUserReactionEmoji === emoji;
      if (!isRemoving) {
        recordReactionUsage(emoji);
      }

      try {
        await this.$store.dispatch('toggleMessageReaction', {
          conversationId: this.conversationId,
          messageId: this.messageId,
          emoji,
        });
        this.handleClose();
      } catch (error) {
        useAlert(this.$t('CONVERSATION.REACTIONS.ERROR'));
      } finally {
        this.isSubmittingReaction = false;
      }
    },
    handleTranslate() {
      const { locale: accountLocale } = this.getAccount(this.currentAccountId);
      const agentLocale = this.getUISettings?.locale;
      const targetLanguage = agentLocale || accountLocale || 'ru';
      this.$store.dispatch('translateMessage', {
        conversationId: this.conversationId,
        messageId: this.messageId,
        targetLanguage,
      });
      useTrack(CONVERSATION_EVENTS.TRANSLATE_A_MESSAGE);
      this.handleClose();
    },
    handleReplyTo() {
      this.$emit('replyTo', this.message);
      this.handleClose();
    },
    handleEdit() {
      this.$emit('edit', this.message);
      this.handleClose();
    },
    openDeleteModal() {
      this.handleClose();
      this.showDeleteModal = true;
    },
    async confirmDeletion() {
      try {
        await this.$store.dispatch('deleteMessage', {
          conversationId: this.conversationId,
          messageId: this.messageId,
        });
        useAlert(this.$t('CONVERSATION.SUCCESS_DELETE_MESSAGE'));
        this.handleClose();
      } catch (error) {
        useAlert(this.$t('CONVERSATION.FAIL_DELETE_MESSSAGE'));
      }
    },
    closeDeleteModal() {
      this.showDeleteModal = false;
    },
  },
};
</script>

<template>
  <div class="context-menu">
    <!-- Add To Canned Responses -->
    <woot-modal
      v-if="isCannedResponseModalOpen && enabledOptions['cannedResponse']"
      v-model:show="isCannedResponseModalOpen"
      @close="hideCannedResponseModal"
    >
      <AddCannedModal
        :response-content="plainTextContent"
        :on-close="hideCannedResponseModal"
      />
    </woot-modal>
    <!-- Confirm Deletion -->
    <woot-delete-modal
      v-if="showDeleteModal && enabledOptions['delete']"
      v-model:show="showDeleteModal"
      class="context-menu--delete-modal"
      :on-close="closeDeleteModal"
      :on-confirm="confirmDeletion"
      :title="$t('CONVERSATION.CONTEXT_MENU.DELETE_CONFIRMATION.TITLE')"
      :message="$t('CONVERSATION.CONTEXT_MENU.DELETE_CONFIRMATION.MESSAGE')"
      :confirm-text="$t('CONVERSATION.CONTEXT_MENU.DELETE_CONFIRMATION.DELETE')"
      :reject-text="$t('CONVERSATION.CONTEXT_MENU.DELETE_CONFIRMATION.CANCEL')"
    />
    <NextButton
      v-if="!hideButton"
      ghost
      slate
      sm
      icon="i-lucide-ellipsis-vertical"
      class="invisible group-hover/context-menu:visible"
      @click="handleOpen"
    />
    <ContextMenu
      v-if="isOpen && !isCannedResponseModalOpen"
      :x="contextMenuPosition.x"
      :y="contextMenuPosition.y"
      @close="handleClose"
    >
      <div class="menu-container">
        <div
          v-if="enabledOptions['react']"
          class="flex items-center gap-1 px-1.5 py-1 select-none"
          data-testid="quick-reaction-bar"
        >
          <button
            v-for="emoji in quickReactions"
            :key="emoji"
            type="button"
            class="emoji-font inline-flex items-center justify-center w-9 h-9 rounded-full text-xl leading-none transition-transform duration-150 hover:scale-125 hover:bg-n-alpha-2 cursor-pointer"
            :class="{
              'bg-n-brand/15 ring-1 ring-n-brand/50':
                currentUserReactionEmoji === emoji,
            }"
            :disabled="isSubmittingReaction"
            @click.stop="handleQuickReaction(emoji)"
          >
            <AppleEmoji :emoji="emoji" size-class="size-7" />
          </button>
          <button
            type="button"
            :title="$t('CONVERSATION.REACTIONS.MORE')"
            data-testid="open-reaction-picker"
            class="inline-flex items-center justify-center w-8 h-8 rounded-full text-n-slate-11 hover:text-n-slate-12 hover:bg-n-alpha-2 transition-colors cursor-pointer"
            :class="{
              'bg-n-alpha-2 text-n-slate-12': showReactionPicker,
            }"
            @click.stop="toggleReactionPicker"
          >
            <span class="i-lucide-plus size-5" />
          </button>
        </div>
        <div
          v-if="enabledOptions['react'] && showReactionPicker"
          class="px-1 py-1 w-[21rem]"
          @click.stop
        >
          <EmojiInput :on-click="handleQuickReaction" inline />
        </div>
        <hr v-if="enabledOptions['react']" />
        <MenuItem
          v-if="enabledOptions['replyTo']"
          :option="{
            icon: 'arrow-reply',
            label: $t('CONVERSATION.CONTEXT_MENU.REPLY_TO'),
          }"
          variant="icon"
          @click.stop="handleReplyTo"
        />
        <MenuItem
          v-if="enabledOptions['edit']"
          :option="{
            icon: 'edit',
            label: $t('CONVERSATION.CONTEXT_MENU.EDIT'),
          }"
          variant="icon"
          @click.stop="handleEdit"
        />
        <MenuItem
          v-if="enabledOptions['copy']"
          :option="{
            icon: 'clipboard',
            label: $t('CONVERSATION.CONTEXT_MENU.COPY'),
          }"
          variant="icon"
          @click.stop="handleCopy"
        />
        <MenuItem
          v-if="enabledOptions['translate']"
          :option="{
            icon: 'translate',
            label: $t('CONVERSATION.CONTEXT_MENU.TRANSLATE'),
          }"
          variant="icon"
          @click.stop="handleTranslate"
        />
        <hr />
        <MenuItem
          v-if="enabledOptions['copyLink']"
          :option="{
            icon: 'link',
            label: $t('CONVERSATION.CONTEXT_MENU.COPY_PERMALINK'),
          }"
          variant="icon"
          @click.stop="copyLinkToMessage"
        />
        <MenuItem
          v-if="enabledOptions['cannedResponse']"
          :option="{
            icon: 'comment-add',
            label: $t('CONVERSATION.CONTEXT_MENU.CREATE_A_CANNED_RESPONSE'),
          }"
          variant="icon"
          @click.stop="showCannedResponseModal"
        />
        <hr v-if="enabledOptions['delete']" />
        <MenuItem
          v-if="enabledOptions['delete']"
          :option="{
            icon: 'delete',
            label: $t('CONVERSATION.CONTEXT_MENU.DELETE'),
          }"
          variant="icon"
          @click.stop="openDeleteModal"
        />
      </div>
    </ContextMenu>
  </div>
</template>

<style lang="scss" scoped>
.menu-container {
  @apply p-1 bg-n-background shadow-xl rounded-md;

  hr:first-child {
    @apply hidden;
  }

  hr {
    @apply m-1 border-b border-solid border-n-strong;
  }
}

.context-menu--delete-modal {
  ::v-deep {
    .modal-container {
      @apply max-w-[30rem];

      h2 {
        @apply font-medium text-base;
      }
    }
  }
}
</style>
