import * as types from '../mutation-types';
import ConversationAPI from '../../api/conversations';
import CommunicationThreadAPI from '../../api/inbox/communicationThread';

const hasOwnProperty = (object, key) =>
  Object.prototype.hasOwnProperty.call(object, key);

const resolveLabelTarget = (payload, rootGetters = {}) => {
  const hasPayloadObject = payload && typeof payload === 'object';
  const conversationId = hasPayloadObject ? payload.conversationId : payload;
  const selectedChat = rootGetters.getSelectedChat || {};
  const selectedChatIsThread = Boolean(
    selectedChat?.is_communication_thread &&
      Number(selectedChat.id) === Number(conversationId)
  );
  let isCommunicationThread = selectedChatIsThread;
  if (hasPayloadObject && hasOwnProperty(payload, 'isCommunicationThread')) {
    isCommunicationThread = Boolean(payload.isCommunicationThread);
  }

  return { conversationId, isCommunicationThread };
};

const labelsApi = isCommunicationThread =>
  isCommunicationThread ? CommunicationThreadAPI : ConversationAPI;

const state = {
  records: {},
  uiFlags: {
    isFetching: false,
    isUpdating: false,
    isError: false,
  },
};

export const getters = {
  getUIFlags($state) {
    return $state.uiFlags;
  },
  getConversationLabels: $state => id => {
    return $state.records[Number(id)] || [];
  },
};

export const actions = {
  get: async ({ commit, rootGetters }, payload) => {
    const { conversationId, isCommunicationThread } = resolveLabelTarget(
      payload,
      rootGetters
    );
    if (
      payload &&
      typeof payload === 'object' &&
      hasOwnProperty(payload, 'labels') &&
      Array.isArray(payload.labels)
    ) {
      commit(types.default.SET_CONVERSATION_LABELS, {
        id: conversationId,
        data: payload.labels,
      });
      return;
    }
    commit(types.default.SET_CONVERSATION_LABELS_UI_FLAG, {
      isFetching: true,
    });
    try {
      const api = labelsApi(isCommunicationThread);
      const response = isCommunicationThread
        ? await api.labels(conversationId)
        : await api.getLabels(conversationId);
      commit(types.default.SET_CONVERSATION_LABELS, {
        id: conversationId,
        data: response.data.payload,
      });
      commit(types.default.SET_CONVERSATION_LABELS_UI_FLAG, {
        isFetching: false,
      });
    } catch (error) {
      commit(types.default.SET_CONVERSATION_LABELS_UI_FLAG, {
        isFetching: false,
      });
    }
  },
  update: async ({ commit, rootGetters }, payload) => {
    const { labels } = payload;
    const { conversationId, isCommunicationThread } = resolveLabelTarget(
      payload,
      rootGetters
    );
    commit(types.default.SET_CONVERSATION_LABELS_UI_FLAG, {
      isUpdating: true,
    });
    try {
      const api = labelsApi(isCommunicationThread);
      const response = isCommunicationThread
        ? await api.updateLabels(conversationId, labels)
        : await api.updateLabels(conversationId, labels);
      commit(types.default.SET_CONVERSATION_LABELS, {
        id: conversationId,
        data: response.data.payload,
      });
      commit(types.default.SET_CONVERSATION_LABELS_UI_FLAG, {
        isUpdating: false,
        isError: false,
      });
    } catch (error) {
      commit(types.default.SET_CONVERSATION_LABELS_UI_FLAG, {
        isUpdating: false,
        isError: true,
      });
    }
  },
  setBulkConversationLabels({ commit }, conversations) {
    commit(types.default.SET_BULK_CONVERSATION_LABELS, conversations);
  },
  setConversationLabel({ commit }, { id, data }) {
    commit(types.default.SET_CONVERSATION_LABELS, { id, data });
  },
};

export const mutations = {
  [types.default.SET_CONVERSATION_LABELS_UI_FLAG]($state, data) {
    $state.uiFlags = {
      ...$state.uiFlags,
      ...data,
    };
  },
  [types.default.SET_CONVERSATION_LABELS]: ($state, { id, data }) => {
    $state.records = { ...$state.records, [id]: data };
  },
  [types.default.SET_BULK_CONVERSATION_LABELS]: ($state, conversations) => {
    const updatedRecords = { ...$state.records };
    conversations.forEach(conversation => {
      updatedRecords[conversation.id] = conversation.labels;
    });

    $state.records = updatedRecords;
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
