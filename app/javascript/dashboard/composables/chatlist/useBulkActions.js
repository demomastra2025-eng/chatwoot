import { computed, ref, unref } from 'vue';
import { useStore } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store.js';
import { useConversationRequiredAttributes } from 'dashboard/composables/useConversationRequiredAttributes';
import BulkActionsAPI from 'dashboard/api/bulkActions';
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
  const allMatchingSelection = ref(null);
  const isSelectingAll = ref(false);
  const selectionContextKey = ref('');
  const selectionVersion = ref(0);
  let selectionRequestId = 0;

  function resetBulkActions() {
    selectionRequestId += 1;
    selectionVersion.value += 1;
    allMatchingSelection.value = null;
    isSelectingAll.value = false;
    store.dispatch('bulkActions/clearSelectedConversationIds');
    selectedInboxes.value = [];
  }

  function updateMatchingSelectionInboxes() {
    const selection = allMatchingSelection.value;
    if (!selection) return;

    const excluded = new Set(selection.excludedIds);
    selectedInboxes.value = [
      ...new Set(
        selection.ids
          .filter(id => !excluded.has(id))
          .flatMap(id => selection.inboxIdsById[String(id)] || [])
          .map(Number)
      ),
    ];
  }

  function isConversationSelected(id) {
    if (allMatchingSelection.value) {
      const snapshotId = Number(id);
      return (
        allMatchingSelection.value.ids.includes(snapshotId) &&
        !allMatchingSelection.value.excludedIds.includes(snapshotId)
      );
    }
    return selectedConversations.value.includes(id);
  }

  const selectedCount = computed(() =>
    allMatchingSelection.value
      ? allMatchingSelection.value.count -
        allMatchingSelection.value.excludedIds.length
      : selectedConversations.value.length
  );

  function syncAllMatchingSelectionCount() {
    store.dispatch(
      'bulkActions/setAllMatchingSelectionCount',
      allMatchingSelection.value ? selectedCount.value : 0
    );
  }

  const failedCountOf = value =>
    Number(value?.failedCount ?? value?.failed_count ?? 0);
  const skippedCountOf = value =>
    Number(value?.skippedCount ?? value?.skipped_count ?? 0);

  // A failed run reports how many conversations could not be updated.
  const bulkActionFailureMessage = (error, fallbackMessage) => {
    if (error?.code === 'bulk_action_status_unknown') {
      return t('BULK_ACTION.PROGRESS.STATUS_UNAVAILABLE');
    }

    if (error?.response?.data?.error?.code === 'selection_invalid') {
      resetBulkActions();
      return t('BULK_ACTION.SELECT_ALL.EXPIRED');
    }

    if (error?.totalCount !== undefined) {
      return t('BULK_ACTION.PROGRESS.INTERRUPTED', {
        doneCount: Number(error.doneCount || 0),
        skippedCount: Number(error.skippedCount || 0),
        failedCount: Number(error.failedCount || 0),
        remainingCount: Math.max(
          0,
          Number(error.totalCount) - Number(error.processedCount || 0)
        ),
      });
    }

    const failedCount = failedCountOf(error);
    return failedCount > 0
      ? t('BULK_ACTION.PROGRESS.FAILED', { count: failedCount })
      : fallbackMessage;
  };

  // A completed run can still skip some conversations; do not report that
  // as a full success.
  const bulkActionResultMessage = (bulkActionRun, successMessage) => {
    const failedCount = failedCountOf(bulkActionRun);
    const skippedCount = skippedCountOf(bulkActionRun);
    const doneCount = Number(
      bulkActionRun?.done_count ??
        bulkActionRun?.doneCount ??
        Math.max(
          0,
          Number(bulkActionRun?.processed_count || 0) - failedCount - skippedCount
        )
    );
    if (skippedCount > 0) {
      return t('BULK_ACTION.COMPLETED_WITH_DETAILS', {
        doneCount,
        failedCount,
        skippedCount,
      });
    }
    return failedCount > 0
      ? t('BULK_ACTION.COMPLETED_WITH_ERRORS', {
          count: failedCount,
          doneCount,
        })
      : successMessage;
  };

  const normalizeInboxIds = inboxIds => {
    const ids = Array.isArray(inboxIds) ? inboxIds : [inboxIds];
    return ids.filter(Boolean);
  };

  function selectConversation(conversationId, inboxIds) {
    if (allMatchingSelection.value) {
      const snapshotId = Number(conversationId);
      if (allMatchingSelection.value.ids.includes(snapshotId)) {
        allMatchingSelection.value.excludedIds =
          allMatchingSelection.value.excludedIds.filter(
            id => id !== snapshotId
          );
        syncAllMatchingSelectionCount();
        selectionVersion.value += 1;
        updateMatchingSelectionInboxes();
        return;
      }

      const wasSelected = isConversationSelected(conversationId);
      resetBulkActions();
      if (wasSelected) return;
    }

    store.dispatch('bulkActions/setSelectedConversationIds', conversationId);
    selectionVersion.value += 1;
    selectedInboxes.value = [
      ...selectedInboxes.value,
      ...normalizeInboxIds(inboxIds),
    ];
  }

  function deSelectConversation(conversationId, inboxIds) {
    if (allMatchingSelection.value) {
      const snapshotId = Number(conversationId);
      if (allMatchingSelection.value.ids.includes(snapshotId)) {
        if (!isConversationSelected(snapshotId)) return;

        allMatchingSelection.value.excludedIds = [
          ...allMatchingSelection.value.excludedIds,
          snapshotId,
        ];
        if (selectedCount.value === 0) {
          resetBulkActions();
        } else {
          syncAllMatchingSelectionCount();
          selectionVersion.value += 1;
          updateMatchingSelectionInboxes();
        }
        return;
      }

      resetBulkActions();
      return;
    }

    store.dispatch('bulkActions/removeSelectedConversationIds', conversationId);
    selectionVersion.value += 1;
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

  function setSelectionContext(contextKey) {
    const nextContextKey = String(contextKey ?? '');
    if (selectionContextKey.value === nextContextKey) return;

    selectionContextKey.value = nextContextKey;
    resetBulkActions();
  }

  async function selectAllMatching(filters, type, expectedContextKey) {
    const requestContext = String(
      expectedContextKey ?? selectionContextKey.value
    );
    if (requestContext !== selectionContextKey.value) {
      setSelectionContext(requestContext);
    }
    selectionRequestId += 1;
    const requestId = selectionRequestId;
    isSelectingAll.value = true;

    try {
      const {
        data: { payload },
      } = await BulkActionsAPI.selectAll(type, filters);

      if (
        requestId !== selectionRequestId ||
        requestContext !== selectionContextKey.value
      ) {
        return null;
      }

      allMatchingSelection.value = {
        token: payload.token,
        count: Number(payload.count),
        ids: (payload.ids || []).map(Number),
        excludedIds: [],
        inboxIdsById: payload.inbox_ids_by_id || payload.inboxIdsById || {},
      };
      selectionVersion.value += 1;
      store.dispatch('bulkActions/clearSelectedConversationIds');
      syncAllMatchingSelectionCount();
      updateMatchingSelectionInboxes();
      return allMatchingSelection.value;
    } catch (error) {
      if (requestId !== selectionRequestId) return null;

      const responseError = error?.response?.data?.error || {};
      if (responseError.code === 'selection_limit_exceeded') {
        useAlert(
          t('BULK_ACTION.SELECT_ALL.LIMIT', {
            count: responseError.limit || 10000,
          })
        );
      } else if (responseError.code === 'selection_empty') {
        useAlert(t('BULK_ACTION.SELECT_ALL.EMPTY'));
      } else {
        useAlert(t('BULK_ACTION.SELECT_ALL.FAILED'));
      }
      return null;
    } finally {
      if (requestId === selectionRequestId) isSelectingAll.value = false;
    }
  }

  function selectionActionPayload(
    type,
    actionPayload = {},
    idsOverride = null
  ) {
    if (idsOverride !== null) {
      return { type, ids: idsOverride, ...actionPayload };
    }
    if (allMatchingSelection.value) {
      return {
        type,
        selection_token: allMatchingSelection.value.token,
        excluded_ids: allMatchingSelection.value.excludedIds,
        ...actionPayload,
      };
    }
    return { type, ids: selectedConversations.value, ...actionPayload };
  }

  function selectAllConversations(check, conversationList) {
    const availableConversations = unref(conversationList);
    if (allMatchingSelection.value) resetBulkActions();
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
      selectionVersion.value += 1;
    } else {
      resetBulkActions();
    }
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
      const bulkActionRun = await store.dispatch('bulkActions/process', {
        ...selectionActionPayload(
          bulkType(isCommunicationThreadMode),
          { fields: { assignee_id: agent.id } },
          conversationId ? [conversationId] : null
        ),
      });
      if (!conversationId) resetBulkActions();
      if (conversationId) {
        useAlert(
          t('CONVERSATION.CARD_CONTEXT_MENU.API.AGENT_ASSIGNMENT.SUCCESFUL', {
            agentName: agent.name,
            conversationId,
          })
        );
      } else {
        useAlert(
          bulkActionResultMessage(
            bulkActionRun,
            t('BULK_ACTION.ASSIGN_SUCCESFUL')
          )
        );
      }
    } catch (error) {
      useAlert(bulkActionFailureMessage(error, t('BULK_ACTION.ASSIGN_FAILED')));
    }
  }

  // Same method used in context menu, conversationId being passed from there.
  async function onAssignLabels(
    newLabels,
    conversationId = null,
    isCommunicationThreadMode = false
  ) {
    try {
      const bulkActionRun = await store.dispatch('bulkActions/process', {
        ...selectionActionPayload(
          bulkType(isCommunicationThreadMode),
          { labels: { add: newLabels } },
          conversationId ? [conversationId] : null
        ),
      });
      if (!conversationId) resetBulkActions();
      if (conversationId) {
        useAlert(
          t('CONVERSATION.CARD_CONTEXT_MENU.API.LABEL_ASSIGNMENT.SUCCESFUL', {
            labelName: newLabels[0],
            conversationId,
          })
        );
      } else {
        useAlert(
          bulkActionResultMessage(
            bulkActionRun,
            t('BULK_ACTION.LABELS.ASSIGN_SUCCESFUL')
          )
        );
      }
    } catch (error) {
      useAlert(
        bulkActionFailureMessage(error, t('BULK_ACTION.LABELS.ASSIGN_FAILED'))
      );
    }
  }

  // Only used in context menu
  async function onRemoveLabels(labelsToRemove, conversationId = null) {
    try {
      await store.dispatch('bulkActions/process', {
        ...selectionActionPayload(
          'Conversation',
          { labels: { remove: labelsToRemove } },
          conversationId ? [conversationId] : null
        ),
      });

      useAlert(
        t('CONVERSATION.CARD_CONTEXT_MENU.API.LABEL_REMOVAL.SUCCESFUL', {
          labelName: labelsToRemove[0],
          conversationId,
        })
      );
    } catch (error) {
      useAlert(
        bulkActionFailureMessage(
          error,
          t('CONVERSATION.CARD_CONTEXT_MENU.API.LABEL_REMOVAL.FAILED')
        )
      );
    }
  }

  async function onAssignTeamsForBulk(team, isCommunicationThreadMode = false) {
    try {
      const bulkActionRun = await store.dispatch('bulkActions/process', {
        ...selectionActionPayload(bulkType(isCommunicationThreadMode), {
          fields: { team_id: team.id },
        }),
      });
      resetBulkActions();
      useAlert(
        bulkActionResultMessage(
          bulkActionRun,
          t('BULK_ACTION.TEAMS.ASSIGN_SUCCESFUL')
        )
      );
    } catch (error) {
      useAlert(
        bulkActionFailureMessage(error, t('BULK_ACTION.TEAMS.ASSIGN_FAILED'))
      );
    }
  }

  async function onUpdateConversations(
    status,
    snoozedUntil,
    isCommunicationThreadMode = false,
    statusReason = null
  ) {
    if (selectedCount.value === 0) return;

    let conversationIds = selectedConversations.value;
    let skippedCount = 0;

    // If resolving, check for required attributes
    if (
      status === wootConstants.STATUS_TYPE.RESOLVED &&
      !allMatchingSelection.value
    ) {
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
      let bulkActionRun = null;
      if (conversationIds.length > 0 || allMatchingSelection.value) {
        const fields = { status };
        if (statusReason) fields.status_reason = statusReason;

        bulkActionRun = await store.dispatch('bulkActions/process', {
          ...selectionActionPayload(
            bulkType(isCommunicationThreadMode),
            { fields, snoozed_until: snoozedUntil },
            allMatchingSelection.value ? null : conversationIds
          ),
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

      resetBulkActions();

      if (skippedCount > 0 && !bulkActionRun) {
        useAlert(t('BULK_ACTION.RESOLVE.PARTIAL_SUCCESS'));
      } else {
        useAlert(
          bulkActionResultMessage(
            skippedCount > 0
              ? {
                  ...bulkActionRun,
                  skipped_count: skippedCount + skippedCountOf(bulkActionRun),
                }
              : bulkActionRun,
            t('BULK_ACTION.UPDATE.UPDATE_SUCCESFUL')
          )
        );
      }
    } catch (error) {
      useAlert(
        bulkActionFailureMessage(error, t('BULK_ACTION.UPDATE.UPDATE_FAILED'))
      );
    }
  }

  async function onMarkConversationsRead(isCommunicationThreadMode = false) {
    try {
      const bulkActionRun = await store.dispatch('bulkActions/process', {
        ...selectionActionPayload(bulkType(isCommunicationThreadMode), {
          action_name: 'mark_read',
        }),
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
      useAlert(
        bulkActionResultMessage(
          bulkActionRun,
          t('BULK_ACTION.MARK_READ.SUCCESS')
        )
      );
    } catch (error) {
      useAlert(
        bulkActionFailureMessage(error, t('BULK_ACTION.MARK_READ.FAILED'))
      );
    }
  }

  return {
    selectedConversations,
    selectedCount,
    selectedInboxes,
    allMatchingSelection,
    isSelectingAll,
    selectionVersion,
    selectionContextKey,
    selectConversation,
    deSelectConversation,
    selectAllConversations,
    selectAllMatching,
    setSelectionContext,
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
