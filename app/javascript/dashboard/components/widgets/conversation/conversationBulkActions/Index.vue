<script>
import { getUnixTime } from 'date-fns';
import { mapGetters } from 'vuex';
import { findSnoozeTime } from 'dashboard/helper/snoozeHelpers';
import { emitter } from 'shared/helpers/mitt';
import wootConstants from 'dashboard/constants/globals';
import {
  CMD_BULK_ACTION_SNOOZE_CONVERSATION,
  CMD_BULK_ACTION_REOPEN_CONVERSATION,
  CMD_BULK_ACTION_RESOLVE_CONVERSATION,
} from 'dashboard/helper/commandbar/events';

import NextButton from 'dashboard/components-next/button/Button.vue';
import AgentSelector from './AgentSelector.vue';
import UpdateActions from './UpdateActions.vue';
import LabelActions from './LabelActions.vue';
import TeamActions from './TeamActions.vue';
import CustomSnoozeModal from 'dashboard/components/CustomSnoozeModal.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
export default {
  components: {
    AgentSelector,
    UpdateActions,
    LabelActions,
    TeamActions,
    CustomSnoozeModal,
    NextButton,
    Checkbox,
  },
  props: {
    conversations: {
      type: Array,
      default: () => [],
    },
    allConversationsSelected: {
      type: Boolean,
      default: false,
    },
    selectedInboxes: {
      type: Array,
      default: () => [],
    },
    showOpenAction: {
      type: Boolean,
      default: false,
    },
    showResolvedAction: {
      type: Boolean,
      default: false,
    },
    showSnoozedAction: {
      type: Boolean,
      default: false,
    },
  },
  emits: [
    'selectAllConversations',
    'assignAgent',
    'updateConversations',
    'assignLabels',
    'assignTeam',
    'markRead',
    'resolveConversations',
  ],
  data() {
    return {
      showAgentsList: false,
      showUpdateActions: false,
      showLabelActions: false,
      showTeamsList: false,
      popoverPositions: {},
      showCustomTimeSnoozeModal: false,
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'bulkActions/getUIFlags',
      bulkActionRun: 'bulkActions/getCurrentBulkActionRun',
    }),
    progressPercentage() {
      return this.bulkActionRun?.progress_percentage || 0;
    },
    progressLabel() {
      if (!this.bulkActionRun) {
        return '';
      }

      const actionName = this.bulkActionRun.action_name;
      let actionLabel = this.$t('BULK_ACTION.PROGRESS.ACTIONS.update');

      if (actionName === 'add_labels') {
        actionLabel = this.$t('BULK_ACTION.PROGRESS.ACTIONS.add_labels');
      } else if (actionName === 'remove_labels') {
        actionLabel = this.$t('BULK_ACTION.PROGRESS.ACTIONS.remove_labels');
      } else if (actionName === 'assign_agent') {
        actionLabel = this.$t('BULK_ACTION.PROGRESS.ACTIONS.assign_agent');
      } else if (actionName === 'assign_team') {
        actionLabel = this.$t('BULK_ACTION.PROGRESS.ACTIONS.assign_team');
      } else if (actionName === 'update_status') {
        actionLabel = this.$t('BULK_ACTION.PROGRESS.ACTIONS.update_status');
      } else if (actionName === 'mark_read') {
        actionLabel = this.$t('BULK_ACTION.PROGRESS.ACTIONS.mark_read');
      }

      return this.$t('BULK_ACTION.PROGRESS.TITLE', {
        action: actionLabel,
        processedCount: this.bulkActionRun.processed_count || 0,
        totalCount: this.bulkActionRun.total_count || 0,
      });
    },
    progressMetaLabel() {
      if (!this.bulkActionRun?.failed_count) {
        return '';
      }

      return this.$t('BULK_ACTION.PROGRESS.FAILED', {
        count: this.bulkActionRun.failed_count,
      });
    },
  },
  mounted() {
    emitter.on(
      CMD_BULK_ACTION_SNOOZE_CONVERSATION,
      this.onCmdSnoozeConversation
    );
    emitter.on(
      CMD_BULK_ACTION_REOPEN_CONVERSATION,
      this.onCmdReopenConversation
    );
    emitter.on(
      CMD_BULK_ACTION_RESOLVE_CONVERSATION,
      this.onCmdResolveConversation
    );
  },
  unmounted() {
    emitter.off(
      CMD_BULK_ACTION_SNOOZE_CONVERSATION,
      this.onCmdSnoozeConversation
    );
    emitter.off(
      CMD_BULK_ACTION_REOPEN_CONVERSATION,
      this.onCmdReopenConversation
    );
    emitter.off(
      CMD_BULK_ACTION_RESOLVE_CONVERSATION,
      this.onCmdResolveConversation
    );
  },
  methods: {
    onCmdSnoozeConversation(snoozeType) {
      if (snoozeType === wootConstants.SNOOZE_OPTIONS.UNTIL_CUSTOM_TIME) {
        this.showCustomTimeSnoozeModal = true;
      } else if (typeof snoozeType === 'number') {
        this.updateConversations('snoozed', snoozeType);
      } else {
        this.updateConversations('snoozed', findSnoozeTime(snoozeType) || null);
      }
    },
    onCmdReopenConversation() {
      this.updateConversations('open', null);
    },
    onCmdResolveConversation() {
      this.updateConversations('resolved', null);
    },
    customSnoozeTime(customSnoozedTime) {
      this.showCustomTimeSnoozeModal = false;
      if (customSnoozedTime) {
        this.updateConversations('snoozed', getUnixTime(customSnoozedTime));
      }
    },
    hideCustomSnoozeModal() {
      this.showCustomTimeSnoozeModal = false;
    },
    selectAll(e) {
      this.$emit('selectAllConversations', e.target.checked);
    },
    submit(agent) {
      this.$emit('assignAgent', agent);
    },
    updateConversations(status, snoozedUntil) {
      this.$emit('updateConversations', status, snoozedUntil);
    },
    assignLabels(labels) {
      this.$emit('assignLabels', labels);
    },
    assignTeam(team) {
      this.$emit('assignTeam', team);
    },
    markRead() {
      this.$emit('markRead');
    },
    resolveConversations() {
      this.$emit('resolveConversations');
    },
    toggleUpdateActions() {
      this.showUpdateActions = !this.showUpdateActions;
    },
    toggleLabelActions() {
      this.showLabelActions = !this.showLabelActions;
    },
    toggleAgentList() {
      this.showAgentsList = !this.showAgentsList;
    },
    toggleTeamsList() {
      this.showTeamsList = !this.showTeamsList;
    },
  },
};
</script>

<template>
  <div class="bulk-action__container">
    <div class="flex items-center justify-between">
      <label class="flex items-center justify-between bulk-action__panel">
        <Checkbox
          :model-value="allConversationsSelected"
          class="checkbox"
          :indeterminate="!allConversationsSelected"
          :disabled="uiFlags.isUpdating"
          @change="selectAll($event)"
        />
        <span>
          {{
            $t('BULK_ACTION.CONVERSATIONS_SELECTED', {
              conversationCount: conversations.length,
            })
          }}
        </span>
      </label>
      <div class="flex items-center gap-1 bulk-action__actions">
        <NextButton
          v-tooltip="$t('BULK_ACTION.LABELS.ASSIGN_LABELS')"
          icon="i-lucide-tags"
          slate
          xs
          faded
          :disabled="uiFlags.isUpdating"
          @click="toggleLabelActions"
        />
        <NextButton
          v-tooltip="$t('BULK_ACTION.MARK_READ.TOOLTIP')"
          icon="i-lucide-mail-open"
          slate
          xs
          faded
          :disabled="uiFlags.isUpdating"
          @click="markRead"
        />
        <NextButton
          v-tooltip="$t('BULK_ACTION.UPDATE.CHANGE_STATUS')"
          icon="i-lucide-repeat"
          slate
          xs
          faded
          :disabled="uiFlags.isUpdating"
          @click="toggleUpdateActions"
        />
        <NextButton
          v-tooltip="$t('BULK_ACTION.ASSIGN_AGENT_TOOLTIP')"
          icon="i-lucide-user-round-plus"
          slate
          xs
          faded
          :disabled="uiFlags.isUpdating"
          @click="toggleAgentList"
        />
        <NextButton
          v-tooltip="$t('BULK_ACTION.ASSIGN_TEAM_TOOLTIP')"
          icon="i-lucide-users-round"
          slate
          xs
          faded
          :disabled="uiFlags.isUpdating"
          @click="toggleTeamsList"
        />
      </div>
      <transition name="popover-animation">
        <LabelActions
          v-if="showLabelActions"
          class="label-actions-box"
          @assign="assignLabels"
          @close="showLabelActions = false"
        />
      </transition>
      <transition name="popover-animation">
        <UpdateActions
          v-if="showUpdateActions"
          class="update-actions-box"
          :selected-inboxes="selectedInboxes"
          :conversation-count="conversations.length"
          :show-resolve="!showResolvedAction"
          :show-reopen="!showOpenAction"
          :show-snooze="!showSnoozedAction"
          @update="updateConversations"
          @close="showUpdateActions = false"
        />
      </transition>
      <transition name="popover-animation">
        <AgentSelector
          v-if="showAgentsList"
          class="agent-actions-box"
          :selected-inboxes="selectedInboxes"
          :conversation-count="conversations.length"
          @select="submit"
          @close="showAgentsList = false"
        />
      </transition>
      <transition name="popover-animation">
        <TeamActions
          v-if="showTeamsList"
          class="team-actions-box"
          @assign-team="assignTeam"
          @close="showTeamsList = false"
        />
      </transition>
    </div>
    <div v-if="allConversationsSelected" class="bulk-action__alert">
      {{ $t('BULK_ACTION.ALL_CONVERSATIONS_SELECTED_ALERT') }}
    </div>
    <div
      v-if="uiFlags.isUpdating && bulkActionRun"
      class="bulk-action__progress"
    >
      <div class="flex items-center justify-between gap-3">
        <span class="bulk-action__progress-label">
          {{ progressLabel }}
        </span>
        <span v-if="progressMetaLabel" class="bulk-action__progress-meta">
          {{ progressMetaLabel }}
        </span>
      </div>
      <div class="bulk-action__progress-track">
        <div
          class="bulk-action__progress-fill"
          :style="{ width: `${progressPercentage}%` }"
        />
      </div>
    </div>
    <woot-modal
      v-model:show="showCustomTimeSnoozeModal"
      @close="hideCustomSnoozeModal"
    >
      <CustomSnoozeModal
        @close="hideCustomSnoozeModal"
        @choose-time="customSnoozeTime"
      />
    </woot-modal>
  </div>
</template>

<style scoped lang="scss">
.bulk-action__container {
  @apply p-3 relative border-b border-solid border-n-strong dark:border-n-weak;
}

.bulk-action__panel {
  @apply cursor-pointer;

  span {
    @apply text-xs my-0 mx-1;
  }

  input[type='checkbox'] {
    @apply cursor-pointer m-0;
  }
}

.bulk-action__alert {
  @apply bg-n-amber-3 text-n-amber-12 rounded text-xs mt-2 py-1 px-2 border border-solid border-n-amber-5;
}

.bulk-action__progress {
  @apply mt-2 rounded-lg border border-solid border-n-weak bg-n-alpha-2 px-2.5 py-2;
}

.bulk-action__progress-label {
  @apply text-xs font-medium text-n-slate-12;
}

.bulk-action__progress-meta {
  @apply text-[11px] text-n-slate-10 tabular-nums;
}

.bulk-action__progress-track {
  @apply mt-2 h-1.5 overflow-hidden rounded-full bg-n-alpha-3;
}

.bulk-action__progress-fill {
  @apply h-full rounded-full bg-n-blue-9 transition-all duration-300 ease-out;
}

.popover-animation-enter-active,
.popover-animation-leave-active {
  transition: transform ease-out 0.1s;
}

.popover-animation-enter {
  transform: scale(0.95);
  @apply opacity-0;
}

.popover-animation-enter-to {
  transform: scale(1);
  @apply opacity-100;
}

.popover-animation-leave {
  transform: scale(1);
  @apply opacity-100;
}

.popover-animation-leave-to {
  transform: scale(0.95);
  @apply opacity-0;
}

.label-actions-box {
  --triangle-position: 5.3125rem;
}
.update-actions-box {
  --triangle-position: 3.5rem;
}
.agent-actions-box {
  --triangle-position: 1.75rem;
}
.team-actions-box {
  --triangle-position: 0.125rem;
}
</style>
