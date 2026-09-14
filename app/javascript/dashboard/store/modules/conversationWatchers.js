import types from '../mutation-types';
import { throwErrorMessage } from 'dashboard/store/utils/api';

import ConversationInboxApi from '../../api/inbox/conversation';
import CommunicationThreadApi from '../../api/inbox/communicationThread';

const state = {
  records: {},
  uiFlags: {
    isFetching: false,
    isUpdating: false,
  },
};

const participantRecordKey = (conversationId, communicationThreadMode) =>
  `${communicationThreadMode ? 'thread' : 'conversation'}:${conversationId}`;
const activeParticipantRequests = new Map();

export const getters = {
  getUIFlags($state) {
    return $state.uiFlags;
  },
  getByConversationId:
    _state =>
    (conversationId, communicationThreadMode = false) =>
      _state.records[
        participantRecordKey(conversationId, communicationThreadMode)
      ],
};

const updateCommunicationThreadParticipants = async ({
  conversationId,
  userIds,
  currentParticipants,
}) => {
  const currentIds = currentParticipants.map(({ id }) => id);
  const addedIds = userIds.filter(id => !currentIds.includes(id));
  const removedIds = currentIds.filter(id => !userIds.includes(id));
  if (addedIds.length + removedIds.length !== 1) {
    throw new Error('Participants must be changed one at a time');
  }

  return addedIds.length
    ? CommunicationThreadApi.addParticipant(conversationId, addedIds[0])
    : CommunicationThreadApi.removeParticipant(conversationId, removedIds[0]);
};

export const actions = {
  show: async (
    { commit },
    { conversationId, communicationThreadMode = false }
  ) => {
    const recordKey = participantRecordKey(
      conversationId,
      communicationThreadMode
    );
    const requestToken = Symbol(recordKey);
    activeParticipantRequests.set(recordKey, requestToken);
    commit(types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, {
      isFetching: true,
    });

    try {
      const response = communicationThreadMode
        ? await CommunicationThreadApi.fetchParticipants(conversationId)
        : await ConversationInboxApi.fetchParticipants(conversationId);
      if (activeParticipantRequests.get(recordKey) !== requestToken) return;

      commit(types.SET_CONVERSATION_PARTICIPANTS, {
        conversationId,
        communicationThreadMode,
        data: response.data,
      });
    } catch (error) {
      if (activeParticipantRequests.get(recordKey) === requestToken) {
        throwErrorMessage(error);
      }
    } finally {
      if (activeParticipantRequests.get(recordKey) === requestToken) {
        activeParticipantRequests.delete(recordKey);
        commit(types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, {
          isFetching: false,
        });
      }
    }
  },

  update: async (
    { commit, state: $state },
    { conversationId, userIds, communicationThreadMode = false }
  ) => {
    commit(types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, {
      isUpdating: true,
    });

    try {
      const response = communicationThreadMode
        ? await updateCommunicationThreadParticipants({
            conversationId,
            userIds,
            currentParticipants:
              $state.records[
                participantRecordKey(conversationId, communicationThreadMode)
              ] || [],
          })
        : await ConversationInboxApi.updateParticipants({
            conversationId,
            userIds,
          });
      commit(types.SET_CONVERSATION_PARTICIPANTS, {
        conversationId,
        communicationThreadMode,
        data: response.data,
      });
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG, {
        isUpdating: false,
      });
    }
  },
};

export const mutations = {
  [types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG]($state, data) {
    $state.uiFlags = {
      ...$state.uiFlags,
      ...data,
    };
  },

  [types.SET_CONVERSATION_PARTICIPANTS](
    $state,
    { data, conversationId, communicationThreadMode = false }
  ) {
    $state.records = {
      ...$state.records,
      [participantRecordKey(conversationId, communicationThreadMode)]: data,
    };
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
