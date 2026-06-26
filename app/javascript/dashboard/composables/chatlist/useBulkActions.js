import { ref, unref } from 'vue';
import { useStore } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store.js';
import { useConversationRequiredAttributes } from 'dashboard/composables/useConversationRequiredAttributes';
import wootConstants from 'dashboard/constants/globals';
import mutationTypes from 'dashboard/store/mutation-types';

export function useBulkActions() {
  const store = useStore();
  const { t } = useI18n();
  const { checkMissingAttributes } = useConversationRequiredAttributes();

  const selectedConversations = useMapGetter(
    'bulkActions/getSelectedConversationIds'
  );
  const selectedInboxes = ref([]);

  const normalizeInboxIds = inboxIds => {
    const ids = Array.isArray(inboxIds) ? inboxIds : [inboxIds];
    return ids.filter(Boolean);
  };

  function selectConversation(conversationId, inboxIds) {
    store.dispatch('bulkActions/setSelectedConversationIds', conversationId);
    selectedInboxes.value = [
      ...selectedInboxes.value,
      ...normalizeInboxIds(inboxIds),
    ];
  }

  function deSelectConversation(conversationId, inboxIds) {
    store.dispatch('bulkActions/removeSelectedConversationIds', conversationId);
    normalizeInboxIds(inboxIds).forEach(inboxId => {
      const index = selectedInboxes.value.indexOf(inboxId);

      if (index > -1) {
        selectedInboxes.value = [
          ...selectedInboxes.value.slice(0, index),
          ...selectedInboxes.value.slice(index + 1),
        ];
      }
    });
  }

  function resetBulkActions() {
    store.dispatch('bulkActions/clearSelectedConversationIds');
    selectedInboxes.value = [];
  }

  function selectAllConversations(check, conversationList) {
    const availableConversations = unref(conversationList);
    if (check) {
      store.dispatch(
        'bulkActions/setSelectedConversationIds',
        availableConversations.map(item => item.id)
      );
      selectedInboxes.value = availableConversations.flatMap(item =>
        item?.is_communication_thread
          ? (item.channels || [])
              .map(channel => channel.inbox_id)
              .filter(Boolean)
          : [item.inbox_id].filter(Boolean)
      );
    } else {
      resetBulkActions();
    }
  }

  function isConversationSelected(id) {
    return selectedConversations.value.includes(id);
  }

  // Same method used in context menu, conversationId being passed from there.
  function bulkType(isCommunicationThreadMode = false) {
    return isCommunicationThreadMode ? 'CommunicationThread' : 'Conversation';
  }

  function storeConversationType(isCommunicationThreadMode = false) {
    return isCommunicationThreadMode ? 'communication_thread' : 'conversation';
  }

  async function onAssignAgent(
    agent,
    conversationId = null,
    isCommunicationThreadMode = false
  ) {
    try {
      await store.dispatch('bulkActions/process', {
        type: bulkType(isCommunicationThreadMode),
        ids: conversationId || selectedConversations.value,
        fields: {
          assignee_id: agent.id,
        },
      });
      store.dispatch('bulkActions/clearSelectedConversationIds');
      if (conversationId) {
        useAlert(
          t('CONVERSATION.CARD_CONTEXT_MENU.API.AGENT_ASSIGNMENT.SUCCESFUL', {
            agentName: agent.name,
            conversationId,
          })
        );
      } else {
        useAlert(t('BULK_ACTION.ASSIGN_SUCCESFUL'));
      }
    } catch (err) {
      useAlert(t('BULK_ACTION.ASSIGN_FAILED'));
    }
  }

  // Same method used in context menu, conversationId being passed from there.
  async function onAssignLabels(
    newLabels,
    conversationId = null,
    isCommunicationThreadMode = false
  ) {
    try {
      await store.dispatch('bulkActions/process', {
        type: bulkType(isCommunicationThreadMode),
        ids: conversationId || selectedConversations.value,
        labels: {
          add: newLabels,
        },
      });
      store.dispatch('bulkActions/clearSelectedConversationIds');
      if (conversationId) {
        useAlert(
          t('CONVERSATION.CARD_CONTEXT_MENU.API.LABEL_ASSIGNMENT.SUCCESFUL', {
            labelName: newLabels[0],
            conversationId,
          })
        );
      } else {
        useAlert(t('BULK_ACTION.LABELS.ASSIGN_SUCCESFUL'));
      }
    } catch (err) {
      useAlert(t('BULK_ACTION.LABELS.ASSIGN_FAILED'));
    }
  }

  // Only used in context menu
  async function onRemoveLabels(labelsToRemove, conversationId = null) {
    try {
      await store.dispatch('bulkActions/process', {
        type: 'Conversation',
        ids: conversationId || selectedConversations.value,
        labels: {
          remove: labelsToRemove,
        },
      });

      useAlert(
        t('CONVERSATION.CARD_CONTEXT_MENU.API.LABEL_REMOVAL.SUCCESFUL', {
          labelName: labelsToRemove[0],
          conversationId,
        })
      );
    } catch (err) {
      useAlert(t('CONVERSATION.CARD_CONTEXT_MENU.API.LABEL_REMOVAL.FAILED'));
    }
  }

  async function onAssignTeamsForBulk(team, isCommunicationThreadMode = false) {
    try {
      await store.dispatch('bulkActions/process', {
        type: bulkType(isCommunicationThreadMode),
        ids: selectedConversations.value,
        fields: {
          team_id: team.id,
        },
      });
      store.dispatch('bulkActions/clearSelectedConversationIds');
      useAlert(t('BULK_ACTION.TEAMS.ASSIGN_SUCCESFUL'));
    } catch (err) {
      useAlert(t('BULK_ACTION.TEAMS.ASSIGN_FAILED'));
    }
  }

  async function onUpdateConversations(
    status,
    snoozedUntil,
    isCommunicationThreadMode = false,
    statusReason = null
  ) {
    if (selectedConversations.value.length === 0) return;

    let conversationIds = selectedConversations.value;
    let skippedCount = 0;

    // If resolving, check for required attributes
    if (status === wootConstants.STATUS_TYPE.RESOLVED) {
      const { validIds, skippedIds } = selectedConversations.value.reduce(
        (acc, id) => {
          const conversation = store.getters.getConversationById(
            id,
            storeConversationType(isCommunicationThreadMode)
          );
          const currentCustomAttributes = conversation?.custom_attributes || {};
          const { hasMissing } = checkMissingAttributes(
            currentCustomAttributes
          );

          if (!hasMissing) {
            acc.validIds.push(id);
          } else {
            acc.skippedIds.push(id);
          }
          return acc;
        },
        { validIds: [], skippedIds: [] }
      );

      conversationIds = validIds;
      skippedCount = skippedIds.length;

      if (skippedCount > 0 && validIds.length === 0) {
        // All conversations have missing attributes
        useAlert(
          t('BULK_ACTION.RESOLVE.ALL_MISSING_ATTRIBUTES') ||
            'Cannot resolve conversations due to missing required attributes'
        );
        return;
      }
    }

    try {
      if (conversationIds.length > 0) {
        const fields = { status };
        if (statusReason) fields.status_reason = statusReason;

        await store.dispatch('bulkActions/process', {
          type: bulkType(isCommunicationThreadMode),
          ids: conversationIds,
          fields,
          snoozed_until: snoozedUntil,
        });

        conversationIds.forEach(conversationId => {
          store.commit(mutationTypes.CHANGE_CONVERSATION_STATUS, {
            conversationId,
            status,
            snoozedUntil,
            conversationType: storeConversationType(isCommunicationThreadMode),
          });
        });
      }

      store.dispatch('bulkActions/clearSelectedConversationIds');

      if (skippedCount > 0) {
        useAlert(t('BULK_ACTION.RESOLVE.PARTIAL_SUCCESS'));
      } else {
        useAlert(t('BULK_ACTION.UPDATE.UPDATE_SUCCESFUL'));
      }
    } catch (err) {
      useAlert(t('BULK_ACTION.UPDATE.UPDATE_FAILED'));
    }
  }

  async function onMarkConversationsRead(isCommunicationThreadMode = false) {
    try {
      await store.dispatch('bulkActions/process', {
        type: bulkType(isCommunicationThreadMode),
        ids: selectedConversations.value,
        action_name: 'mark_read',
      });
      selectedConversations.value.forEach(id => {
        store.commit('UPDATE_MESSAGE_UNREAD_COUNT', {
          id,
          lastSeen: new Date().toISOString(),
          unreadCount: 0,
          conversationType: storeConversationType(isCommunicationThreadMode),
        });
      });
      resetBulkActions();
      useAlert(t('BULK_ACTION.MARK_READ.SUCCESS'));
    } catch (err) {
      useAlert(t('BULK_ACTION.MARK_READ.FAILED'));
    }
  }

  return {
    selectedConversations,
    selectedInboxes,
    selectConversation,
    deSelectConversation,
    selectAllConversations,
    resetBulkActions,
    isConversationSelected,
    onAssignAgent,
    onAssignLabels,
    onRemoveLabels,
    onAssignTeamsForBulk,
    onUpdateConversations,
    onMarkConversationsRead,
  };
}
