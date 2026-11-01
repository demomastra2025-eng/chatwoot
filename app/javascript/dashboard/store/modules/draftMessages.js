import types from '../mutation-types';

import { REPLY_EDITOR_MODES } from 'dashboard/components/widgets/WootWriter/constants';
import { LocalStorage } from 'shared/helpers/localStorage';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';

const state = {
  records: LocalStorage.get(LOCAL_STORAGE_KEYS.DRAFT_MESSAGES) || {},
  replyEditorMode: REPLY_EDITOR_MODES.REPLY,
};

export const getters = {
  get: _state => key => {
    const record = _state.records[key];
    return typeof record === 'string' ? record : record?.message || '';
  },
  getRecord: _state => key => {
    const record = _state.records[key];
    return typeof record === 'string' ? { message: record } : record || null;
  },
  getReplyEditorMode: _state => _state.replyEditorMode,
};

export const actions = {
  set: async ({ commit }, payload) => {
    commit(types.SET_DRAFT_MESSAGES, payload);
  },
  delete: ({ commit }, { key }) => {
    commit(types.SET_DRAFT_MESSAGES, { key });
  },
  setReplyEditorMode: ({ commit }, { mode }) => {
    commit(types.SET_REPLY_EDITOR_MODE, { mode });
  },
};

export const mutations = {
  [types.SET_DRAFT_MESSAGES](
    $state,
    { key, message, context = null, aiIdentity = null }
  ) {
    const records = { ...$state.records };
    if (message === undefined) {
      delete records[key];
    } else {
      records[key] = { message, context, aiIdentity };
    }
    // Text, context and identity are one durable record; there is no separate provenance write.
    LocalStorage.set(LOCAL_STORAGE_KEYS.DRAFT_MESSAGES, records);
    $state.records = records;
  },
  [types.REMOVE_DRAFT_MESSAGES]($state, { key }) {
    const { [key]: draftToBeRemoved, ...updatedRecords } = $state.records;
    $state.records = updatedRecords;
    LocalStorage.set(LOCAL_STORAGE_KEYS.DRAFT_MESSAGES, $state.records);
  },
  [types.SET_REPLY_EDITOR_MODE]($state, { mode }) {
    $state.replyEditorMode = mode;
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
