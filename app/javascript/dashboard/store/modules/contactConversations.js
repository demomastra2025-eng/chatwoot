import * as types from '../mutation-types';
import ContactAPI from '../../api/contacts';
import camelcaseKeys from 'camelcase-keys';

const state = {
  records: {},
  uiFlags: {
    isFetching: false,
  },
};

export const getters = {
  getUIFlags($state) {
    return $state.uiFlags;
  },
  getContactConversation: $state => id => {
    return $state.records[Number(id)] || [];
  },
  getAllConversationsByContactId: $state => id => {
    const records = $state.records[Number(id)] || [];
    return camelcaseKeys(records, { deep: true });
  },
};

export const actions = {
  get: async ({ commit }, contactId) => {
    commit(types.default.SET_CONTACT_CONVERSATIONS_UI_FLAG, {
      isFetching: true,
    });
    try {
      const response = await ContactAPI.getConversations(contactId);
      commit(types.default.SET_CONTACT_CONVERSATIONS, {
        id: contactId,
        data: response.data.payload,
      });
      commit(types.default.SET_CONTACT_CONVERSATIONS_UI_FLAG, {
        isFetching: false,
      });
    } catch (error) {
      commit(types.default.SET_CONTACT_CONVERSATIONS_UI_FLAG, {
        isFetching: false,
      });
    }
  },
};

export const mutations = {
  [types.default.SET_CONTACT_CONVERSATIONS_UI_FLAG]($state, data) {
    $state.uiFlags = {
      ...$state.uiFlags,
      ...data,
    };
  },
  [types.default.SET_CONTACT_CONVERSATIONS]: ($state, { id, data }) => {
    $state.records = {
      ...$state.records,
      [id]: data,
    };
  },
  [types.default.ADD_CONTACT_CONVERSATION]: ($state, { id, data }) => {
    const conversations = $state.records[id] || [];

    const updatedConversations = [...conversations];
    const index = conversations.findIndex(
      conversation => conversation.id === data.id
    );

    if (index !== -1) {
      updatedConversations[index] = { ...conversations[index], ...data };
    } else {
      updatedConversations.push(data);
    }

    $state.records = {
      ...$state.records,
      [id]: updatedConversations,
    };
  },
  [types.default.DELETE_CONTACT_CONVERSATION]: ($state, id) => {
    const { [id]: deletedRecord, ...remainingRecords } = $state.records;
    $state.records = remainingRecords;
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
