<script>
import ConversationCard from './widgets/conversation/ConversationCard.vue';
export default {
  components: {
    ConversationCard,
  },
  inject: [
    'selectConversation',
    'deSelectConversation',
    'assignAgent',
    'assignTeam',
    'assignLabels',
    'removeLabels',
    'updateConversationStatus',
    'toggleContextMenu',
    'markAsUnread',
    'markAsRead',
    'assignPriority',
    'isConversationSelected',
    'deleteConversation',
  ],
  props: {
    source: {
      type: Object,
      required: true,
    },
    teamId: {
      type: [String, Number],
      default: 0,
    },
    label: {
      type: String,
      default: '',
    },
    conversationType: {
      type: String,
      default: '',
    },
    activeStatus: {
      type: String,
      default: 'open',
    },
    foldersId: {
      type: [String, Number],
      default: 0,
    },
    showAssignee: {
      type: Boolean,
      default: false,
    },
    communicationThreadMode: {
      type: Boolean,
      default: false,
    },
  },
};
</script>

<template>
  <ConversationCard
    :active-label="label"
    :team-id="teamId"
    :folders-id="foldersId"
    :chat="source"
    :active-status="activeStatus"
    :conversation-type="conversationType"
    :communication-thread-mode="communicationThreadMode"
    :selected="isConversationSelected(source.id)"
    :show-assignee="showAssignee"
    selectable
    enable-context-menu
    :allowed-context-menu-options="
      communicationThreadMode
        ? [
            'priority',
            'status',
            'agent',
            'team',
            'label',
            'delete',
            'open-new-tab',
            'copy-link',
          ]
        : []
    "
    @select-conversation="selectConversation"
    @de-select-conversation="deSelectConversation"
    @assign-agent="assignAgent"
    @assign-team="assignTeam"
    @assign-label="assignLabels"
    @remove-label="removeLabels"
    @update-conversation-status="updateConversationStatus"
    @context-menu-toggle="toggleContextMenu"
    @mark-as-unread="markAsUnread"
    @mark-as-read="markAsRead"
    @assign-priority="assignPriority"
    @delete-conversation="deleteConversation"
  />
</template>
