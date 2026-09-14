<script>
import Spinner from 'shared/components/Spinner.vue';
import { useAlert } from 'dashboard/composables';
import { mapGetters } from 'vuex';
import { useAgentsList } from 'dashboard/composables/useAgentsList';
import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';

import ThumbnailGroup from 'dashboard/components/widgets/ThumbnailGroup.vue';
import MultiselectDropdownItems from 'shared/components/ui/MultiselectDropdownItems.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    Spinner,
    ThumbnailGroup,
    MultiselectDropdownItems,
    NextButton,
  },
  props: {
    conversationId: {
      type: [Number, String],
      required: true,
    },
  },
  setup() {
    const { agentsList } = useAgentsList(false);
    return {
      agentsList,
    };
  },
  data() {
    return {
      selectedWatchers: [],
      showDropDown: false,
      participantFetchSequence: 0,
      isParticipantsLoading: false,
    };
  },
  computed: {
    ...mapGetters({
      watchersUiFlas: 'conversationWatchers/getUIFlags',
      currentUser: 'getCurrentUser',
      currentChat: 'getSelectedChat',
    }),
    canManageParticipants() {
      return this.communicationThreadMode
        ? Boolean(this.currentChat?.can_manage_participants)
        : true;
    },
    canLeaveParticipation() {
      return (
        this.communicationThreadMode &&
        Boolean(this.currentChat?.can_leave_participation)
      );
    },
    communicationThreadMode() {
      return isCommunicationThread(this.currentChat);
    },
    participantContextKey() {
      return `${this.communicationThreadMode}:${this.conversationId}`;
    },
    canToggleOwnParticipation() {
      return this.communicationThreadMode
        ? this.canLeaveParticipation
        : !this.isUserWatching;
    },
    participantControlsDisabled() {
      return this.isParticipantsLoading || this.watchersUiFlas.isUpdating;
    },
    ownParticipationActionLabel() {
      return this.communicationThreadMode
        ? this.$t('CONVERSATION_PARTICIPANTS.LEAVE_CONVERSATION')
        : this.$t('CONVERSATION_PARTICIPANTS.WATCH_CONVERSATION');
    },
    watchersFromStore() {
      return this.$store.getters['conversationWatchers/getByConversationId'](
        this.conversationId,
        this.communicationThreadMode
      );
    },
    watchersList: {
      get() {
        return this.selectedWatchers;
      },
      set(participants) {
        this.selectedWatchers = [...participants];
        const userIds = participants.map(el => el.id);
        this.updateParticipant(userIds);
      },
    },
    isUserWatching() {
      return this.selectedWatchers.some(
        watcher => watcher.id === this.currentUser.id
      );
    },
    thumbnailList() {
      return this.selectedWatchers.slice(0, 4);
    },
    moreAgentCount() {
      const maxThumbnailCount = 4;
      return this.watchersList.length - maxThumbnailCount;
    },
    moreThumbnailsText() {
      if (this.moreAgentCount > 1) {
        return this.$t('CONVERSATION_PARTICIPANTS.REMANING_PARTICIPANTS_TEXT', {
          count: this.moreAgentCount,
        });
      }
      return this.$t('CONVERSATION_PARTICIPANTS.REMANING_PARTICIPANT_TEXT', {
        count: 1,
      });
    },
    showMoreThumbs() {
      return this.moreAgentCount > 0;
    },
    totalWatchersText() {
      if (this.selectedWatchers.length > 1) {
        return this.$t('CONVERSATION_PARTICIPANTS.TOTAL_PARTICIPANTS_TEXT', {
          count: this.selectedWatchers.length,
        });
      }
      return this.$t('CONVERSATION_PARTICIPANTS.TOTAL_PARTICIPANT_TEXT', {
        count: 1,
      });
    },
  },
  watch: {
    participantContextKey() {
      this.selectedWatchers = [...(this.watchersFromStore || [])];
      this.showDropDown = false;
      this.fetchParticipants();
    },
    watchersFromStore(participants = []) {
      this.selectedWatchers = [...participants];
    },
  },
  mounted() {
    this.fetchParticipants();
    this.$store.dispatch('agents/get');
  },
  methods: {
    async fetchParticipants() {
      const conversationId = this.conversationId;
      this.participantFetchSequence += 1;
      const requestSequence = this.participantFetchSequence;
      this.isParticipantsLoading = true;
      try {
        await this.$store.dispatch('conversationWatchers/show', {
          conversationId,
          communicationThreadMode: this.communicationThreadMode,
        });
      } catch (error) {
        useAlert(
          error?.message ||
            this.$t('CONVERSATION_PARTICIPANTS.API.ERROR_MESSAGE')
        );
      } finally {
        if (requestSequence === this.participantFetchSequence) {
          this.isParticipantsLoading = false;
        }
      }
    },
    async updateParticipant(userIds) {
      const conversationId = this.conversationId;
      let alertMessage = this.$t(
        'CONVERSATION_PARTICIPANTS.API.SUCCESS_MESSAGE'
      );

      try {
        await this.$store.dispatch('conversationWatchers/update', {
          conversationId,
          userIds,
          communicationThreadMode: this.communicationThreadMode,
        });
      } catch (error) {
        alertMessage =
          error?.message ||
          this.$t('CONVERSATION_PARTICIPANTS.API.ERROR_MESSAGE');
      } finally {
        useAlert(alertMessage);
      }
      this.fetchParticipants();
    },
    onOpenDropdown() {
      if (this.participantControlsDisabled) return;

      this.showDropDown = true;
    },
    onCloseDropdown() {
      this.showDropDown = false;
    },
    onClickItem(agent) {
      if (this.participantControlsDisabled) return;

      const isAgentSelected = this.watchersList.some(
        participant => participant.id === agent.id
      );

      if (isAgentSelected) {
        const updatedList = this.watchersList.filter(
          participant => participant.id !== agent.id
        );

        this.watchersList = [...updatedList];
      } else {
        this.watchersList = [...this.watchersList, agent];
      }
    },
    onLeave() {
      if (this.participantControlsDisabled) return;

      this.watchersList = this.selectedWatchers.filter(
        participant => participant.id !== this.currentUser.id
      );
    },
    onSelfAssign() {
      if (this.participantControlsDisabled) return;

      this.watchersList = [...this.selectedWatchers, this.currentUser];
    },
    onToggleOwnParticipation() {
      if (this.communicationThreadMode) {
        this.onLeave();
      } else {
        this.onSelfAssign();
      }
    },
  },
};
</script>

<template>
  <div class="relative">
    <div class="flex justify-between">
      <div class="flex justify-between w-full mb-1">
        <div>
          <p v-if="watchersList.length" class="m-0 text-sm total-watchers">
            <Spinner v-if="isParticipantsLoading" size="tiny" />
            {{ totalWatchersText }}
          </p>
          <p v-else class="m-0 text-sm text-n-slate-10">
            {{ $t('CONVERSATION_PARTICIPANTS.NO_PARTICIPANTS_TEXT') }}
          </p>
        </div>
        <NextButton
          v-if="canManageParticipants"
          v-tooltip.left="$t('CONVERSATION_PARTICIPANTS.ADD_PARTICIPANTS')"
          slate
          ghost
          sm
          icon="i-lucide-settings"
          class="relative -top-1"
          :disabled="participantControlsDisabled"
          :title="$t('CONVERSATION_PARTICIPANTS.ADD_PARTICIPANTS')"
          @click="onOpenDropdown"
        />
      </div>
    </div>
    <div class="flex items-center justify-between">
      <ThumbnailGroup
        :more-thumbnails-text="moreThumbnailsText"
        :show-more-thumbnails-count="showMoreThumbs"
        :users-list="thumbnailList"
      />
      <p v-if="isUserWatching" class="m-0 text-sm text-n-slate-10">
        {{ $t('CONVERSATION_PARTICIPANTS.YOU_ARE_WATCHING') }}
      </p>
      <NextButton
        v-if="canToggleOwnParticipation"
        link
        xs
        icon="i-lucide-arrow-right"
        class="!gap-1"
        :disabled="participantControlsDisabled"
        :label="ownParticipationActionLabel"
        @click="onToggleOwnParticipation"
      />
    </div>
    <div
      v-if="canManageParticipants"
      v-on-clickaway="
        () => {
          onCloseDropdown();
        }
      "
      :class="{
        'block visible': showDropDown,
        'hidden invisible': !showDropDown,
      }"
      class="border rounded-lg shadow-lg bg-n-alpha-3 absolute backdrop-blur-[100px] border-n-strong dark:border-n-strong p-2 z-[9999] box-border top-8 w-full"
    >
      <div class="flex items-center justify-between mb-1">
        <h4
          class="m-0 overflow-hidden text-sm whitespace-nowrap text-ellipsis text-n-slate-12"
        >
          {{ $t('CONVERSATION_PARTICIPANTS.ADD_PARTICIPANTS') }}
        </h4>
        <NextButton ghost slate xs icon="i-lucide-x" @click="onCloseDropdown" />
      </div>
      <MultiselectDropdownItems
        :options="agentsList"
        :selected-items="selectedWatchers"
        has-thumbnail
        @select="onClickItem"
      />
    </div>
  </div>
</template>
