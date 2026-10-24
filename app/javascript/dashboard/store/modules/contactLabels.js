import types from '../mutation-types';
import ContactAPI from '../../api/contacts';

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
  getContactLabels: $state => id => {
    return $state.records[Number(id)] || [];
  },
};

export const actions = {
  get: async ({ commit }, contactId) => {
    commit(types.SET_CONTACT_LABELS_UI_FLAG, {
      isFetching: true,
    });
    try {
      const response = await ContactAPI.getContactLabels(contactId);
      commit(types.SET_CONTACT_LABELS, {
        id: contactId,
        data: response.data.payload,
      });
      commit(types.SET_CONTACT_LABELS_UI_FLAG, {
        isFetching: false,
      });
    } catch (error) {
      commit(types.SET_CONTACT_LABELS_UI_FLAG, {
        isFetching: false,
      });
    }
  },
  // Pass add / remove (what changed) rather than labels (the whole list): the server writes the change to the
  // person's contact and all its conversations, and a list that is out of date can no longer erase a label.
  update: async ({ commit, dispatch }, { contactId, labels, add, remove }) => {
    commit(types.SET_CONTACT_LABELS_UI_FLAG, {
      isUpdating: true,
    });
    try {
      const isChange = Array.isArray(add) || Array.isArray(remove);
      const response = isChange
        ? await ContactAPI.changeContactLabels(contactId, { add, remove })
        : await ContactAPI.updateContactLabels(contactId, labels);
      commit(types.SET_CONTACT_LABELS, {
        id: contactId,
        data: response.data.payload,
      });
      commit(types.SET_CONTACT_LABELS_UI_FLAG, {
        isUpdating: false,
        isError: false,
      });
      dispatch('labels/get', null, { root: true });
    } catch (error) {
      commit(types.SET_CONTACT_LABELS_UI_FLAG, {
        isUpdating: false,
        isError: true,
      });
      throw new Error(error);
    }
  },
  setContactLabel({ commit }, { id, data }) {
    commit(types.SET_CONTACT_LABELS, { id, data });
  },
};

export const mutations = {
  [types.SET_CONTACT_LABELS_UI_FLAG]($state, data) {
    $state.uiFlags = {
      ...$state.uiFlags,
      ...data,
    };
  },
  [types.SET_CONTACT_LABELS]: ($state, { id, data }) => {
    $state.records = {
      ...$state.records,
      [id]: data,
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
