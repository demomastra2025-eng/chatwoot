<!-- eslint-disable vue/v-slot-style -->
<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useAgentsList } from 'dashboard/composables/useAgentsList';
import ContactDetailsItem from './ContactDetailsItem.vue';
import MultiselectDropdown from 'shared/components/ui/MultiselectDropdown.vue';
import { CONVERSATION_PRIORITY } from '../../../../shared/constants/messages';
import { CONVERSATION_EVENTS } from '../../../helper/AnalyticsHelper/events';
import { useTrack } from 'dashboard/composables';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    ContactDetailsItem,
    MultiselectDropdown,
    NextButton,
  },
  props: {
    conversationId: {
      type: [Number, String],
      required: true,
    },
  },
  setup() {
    const { agentsList } = useAgentsList();
    return {
      agentsList,
    };
  },
  data() {
    return {
      priorityOptions: [
        {
          id: null,
          name: this.$t('CONVERSATION.PRIORITY.OPTIONS.NONE'),
          icon: 'i-woot-priority-empty',
        },
        {
          id: CONVERSATION_PRIORITY.LOW,
          name: this.$t('CONTACT_PANEL.PRIORITY_LOW'),
          icon: 'i-woot-priority-low',
        },
        {
          id: CONVERSATION_PRIORITY.MEDIUM,
          name: this.$t('CONTACT_PANEL.PRIORITY_MEDIUM'),
          icon: 'i-woot-priority-medium',
        },
        {
          id: CONVERSATION_PRIORITY.HIGH,
          name: this.$t('CONTACT_PANEL.PRIORITY_HIGH'),
          icon: 'i-woot-priority-high',
        },
        {
          id: CONVERSATION_PRIORITY.URGENT,
          name: this.$t('CONTACT_PANEL.PRIORITY_URGENT'),
          icon: 'i-woot-priority-urgent',
        },
      ],
    };
  },
  computed: {
    ...mapGetters({
      currentChat: 'getSelectedChat',
      currentUser: 'getCurrentUser',
      teams: 'teams/getTeams',
    }),
    hasAnAssignedTeam() {
      return !!this.currentChat?.meta?.team;
    },
    teamsList() {
      if (this.hasAnAssignedTeam) {
        return [
          { id: 0, name: this.$t('TEAMS_SETTINGS.LIST.NONE') },
          ...this.teams,
        ];
      }
      return this.teams;
    },
    selectablePriorityOptions() {
      return this.priorityOptions.filter(item => item.id !== null);
    },
    assignedAgent: {
      get() {
        return this.currentChat.meta.assignee;
      },
      set(agent) {
        const agentId = agent ? agent.id : null;
        const conversationId = this.currentChat.id || this.conversationId;
        this.$store.dispatch('setCurrentChatAssignee', {
          conversationId,
          assignee: agent,
        });
        this.$store
          .dispatch('assignAgent', {
            conversationId,
            agentId,
          })
          .then(() => {
            useAlert(this.$t('CONVERSATION.CHANGE_AGENT'));
          });
      },
    },
    assignedTeam: {
      get() {
        return this.currentChat.meta.team;
      },
      set(team) {
        const conversationId = this.currentChat.id || this.conversationId;
        const teamId = team ? team.id : 0;
        this.$store.dispatch('setCurrentChatTeam', { team, conversationId });
        this.$store
          .dispatch('assignTeam', { conversationId, teamId })
          .then(() => {
            useAlert(this.$t('CONVERSATION.CHANGE_TEAM'));
          });
      },
    },
    assignedPriority: {
      get() {
        const selectedOption = this.priorityOptions.find(
          opt => opt.id === this.currentChat.priority
        );

        return selectedOption || this.priorityOptions[0];
      },
      set(priorityItem) {
        const conversationId = this.currentChat.id || this.conversationId;
        const oldValue = this.currentChat?.priority;
        const priority = priorityItem ? priorityItem.id : null;

        this.$store.dispatch('setCurrentChatPriority', {
          priority,
          conversationId,
        });
        this.$store
          .dispatch('assignPriority', { conversationId, priority })
          .then(() => {
            useTrack(CONVERSATION_EVENTS.CHANGE_PRIORITY, {
              oldValue,
              newValue: priority,
              from: 'Conversation Sidebar',
            });
            useAlert(
              this.$t('CONVERSATION.PRIORITY.CHANGE_PRIORITY.SUCCESSFUL', {
                priority: priorityItem
                  ? priorityItem.name
                  : this.$t('CONVERSATION.PRIORITY.OPTIONS.NONE'),
                conversationId,
              })
            );
          });
      },
    },
    showSelfAssign() {
      if (!this.assignedAgent) {
        return true;
      }
      if (this.assignedAgent.id !== this.currentUser.id) {
        return true;
      }
      return false;
    },
  },
  methods: {
    onSelfAssign() {
      const {
        account_id,
        availability_status,
        available_name,
        email,
        id,
        name,
        role,
        avatar_url,
      } = this.currentUser;
      const selfAssign = {
        account_id,
        availability_status,
        available_name,
        email,
        id,
        name,
        role,
        thumbnail: avatar_url,
      };
      this.assignedAgent = selfAssign;
    },
    onClickAssignAgent(selectedItem) {
      if (this.assignedAgent && this.assignedAgent.id === selectedItem.id) {
        this.assignedAgent = null;
      } else {
        this.assignedAgent = selectedItem;
      }
    },

    onClickAssignTeam(selectedItemTeam) {
      if (this.assignedTeam && this.assignedTeam.id === selectedItemTeam.id) {
        this.assignedTeam = null;
      } else {
        this.assignedTeam = selectedItemTeam;
      }
    },

    onClickAssignPriority(selectedPriorityItem) {
      const isSamePriority =
        this.assignedPriority &&
        this.assignedPriority.id === selectedPriorityItem.id;

      this.assignedPriority = isSamePriority ? null : selectedPriorityItem;
    },

    priorityButtonClass(priority) {
      const isSelected = priority.id === this.assignedPriority?.id;
      if (!isSelected) {
        return 'text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12';
      }
      if (priority.id === CONVERSATION_PRIORITY.URGENT) {
        return 'bg-n-ruby-3 text-n-ruby-11 font-semibold shadow-sm ring-1 ring-inset ring-n-ruby-7/40';
      }
      if (priority.id === CONVERSATION_PRIORITY.HIGH) {
        return 'bg-n-amber-3 text-n-amber-11 font-semibold shadow-sm ring-1 ring-inset ring-n-amber-7/40';
      }
      if (priority.id === CONVERSATION_PRIORITY.MEDIUM) {
        return 'bg-n-blue-3 text-n-blue-11 font-semibold shadow-sm ring-1 ring-inset ring-n-blue-7/40';
      }
      return 'bg-n-solid-2 text-n-slate-12 font-semibold shadow-sm ring-1 ring-inset ring-n-weak';
    },
  },
};
</script>

<template>
  <div class="flex flex-col gap-3">
    <div>
      <ContactDetailsItem compact :title="$t('CONTACT_PANEL.ASSIGNEE_LABEL')">
        <template #button>
          <NextButton
            v-if="showSelfAssign"
            link
            xs
            icon="i-lucide-arrow-right"
            class="!gap-1"
            :label="$t('CONVERSATION_SIDEBAR.SELF_ASSIGN')"
            @click="onSelfAssign"
          />
        </template>
      </ContactDetailsItem>
      <MultiselectDropdown
        :options="agentsList"
        :selected-item="assignedAgent"
        :multiselector-title="$t('AGENT_MGMT.MULTI_SELECTOR.TITLE.AGENT')"
        :multiselector-placeholder="$t('AGENT_MGMT.MULTI_SELECTOR.PLACEHOLDER')"
        :no-search-result="
          $t('AGENT_MGMT.MULTI_SELECTOR.SEARCH.NO_RESULTS.AGENT')
        "
        :input-placeholder="
          $t('AGENT_MGMT.MULTI_SELECTOR.SEARCH.PLACEHOLDER.AGENT')
        "
        @select="onClickAssignAgent"
      />
    </div>
    <div>
      <ContactDetailsItem compact :title="$t('CONTACT_PANEL.PRIORITY_LABEL')" />
      <div
        class="grid grid-cols-4 gap-1 rounded-lg border border-n-weak bg-n-alpha-1 p-1"
        role="group"
        :aria-label="$t('CONTACT_PANEL.PRIORITY_LABEL')"
      >
        <button
          v-for="priority in selectablePriorityOptions"
          :key="priority.id"
          type="button"
          :aria-pressed="priority.id === assignedPriority.id"
          class="min-w-0 truncate rounded-md px-1.5 py-1.5 text-center text-xs transition-colors"
          :class="priorityButtonClass(priority)"
          @click="onClickAssignPriority(priority)"
        >
          {{ priority.name }}
        </button>
      </div>
    </div>
  </div>
</template>
