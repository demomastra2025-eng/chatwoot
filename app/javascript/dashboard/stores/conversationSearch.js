import { defineStore } from 'pinia';

import SearchAPI from 'dashboard/api/search';

const searchRequestScopes = new WeakMap();

const createUIFlags = () => ({
  isFetching: false,
  isSearchCompleted: false,
  contact: { isFetching: false },
  conversation: { isFetching: false },
  message: { isFetching: false },
  article: { isFetching: false },
});

const initialState = () => ({
  records: [],
  contactRecords: [],
  conversationRecords: [],
  messageRecords: [],
  articleRecords: [],
  uiFlags: createUIFlags(),
});

const getSearchRequestScope = store => {
  if (!searchRequestScopes.has(store)) {
    searchRequestScopes.set(store, { generation: 0, controller: undefined });
  }
  return searchRequestScopes.get(store);
};

const abortActiveSearch = store => {
  const scope = getSearchRequestScope(store);
  scope.controller?.abort();
  scope.controller = undefined;
};

const currentSearchRequest = store => {
  const scope = getSearchRequestScope(store);
  return {
    generation: scope.generation,
    signal: scope.controller?.signal,
  };
};

const isCurrentSearchRequest = (store, { generation, signal }) =>
  generation === getSearchRequestScope(store).generation && !signal?.aborted;

export const useConversationSearchStore = defineStore('conversationSearch', {
  state: initialState,
  getters: {
    getConversations: state => state.records,
    getContactRecords: state => state.contactRecords,
    getConversationRecords: state => state.conversationRecords,
    getMessageRecords: state => state.messageRecords,
    getArticleRecords: state => state.articleRecords,
    getUIFlags: state => state.uiFlags,
  },
  actions: {
    async get({ q }) {
      const scope = getSearchRequestScope(this);
      abortActiveSearch(this);
      scope.generation += 1;
      this.records = [];
      if (!q) {
        this.uiFlags = { ...this.uiFlags, isFetching: false };
        return;
      }

      scope.controller = new AbortController();
      const request = currentSearchRequest(this);
      this.uiFlags = { ...this.uiFlags, isFetching: true };
      try {
        const {
          data: { payload },
        } = await SearchAPI.get({ q, signal: request.signal });
        if (!isCurrentSearchRequest(this, request)) return;

        this.records = payload;
      } catch (error) {
        // Ignore error
      } finally {
        if (isCurrentSearchRequest(this, request)) {
          this.uiFlags = { ...this.uiFlags, isFetching: false };
          scope.controller = undefined;
        }
      }
    },
    async fullSearch(payload) {
      const { q, ...filters } = payload;
      const scope = getSearchRequestScope(this);
      if (!q && !Object.keys(filters).length) {
        abortActiveSearch(this);
        scope.generation += 1;
        return;
      }

      abortActiveSearch(this);
      scope.generation += 1;
      scope.controller = new AbortController();
      const request = currentSearchRequest(this);
      this.uiFlags = {
        ...this.uiFlags,
        isFetching: true,
        isSearchCompleted: false,
      };
      try {
        await Promise.all([
          this.contactSearch({ q, ...filters }),
          this.conversationSearch({ q, ...filters }),
          this.messageSearch({ q, ...filters }),
          this.articleSearch({ q, ...filters }),
        ]);
      } catch (error) {
        // Ignore error
      } finally {
        if (isCurrentSearchRequest(this, request)) {
          this.uiFlags = {
            ...this.uiFlags,
            isFetching: false,
            isSearchCompleted: true,
          };
          scope.controller = undefined;
        }
      }
    },
    async contactSearch(payload) {
      const { page = 1, ...searchParams } = payload;
      const request = currentSearchRequest(this);
      this.uiFlags.contact = { ...this.uiFlags.contact, isFetching: true };
      try {
        const { data } = await SearchAPI.contacts({
          ...searchParams,
          page,
          signal: request.signal,
        });
        if (!isCurrentSearchRequest(this, request)) return;

        this.contactRecords = [
          ...this.contactRecords,
          ...data.payload.contacts,
        ];
      } catch (error) {
        // Ignore error
      } finally {
        if (isCurrentSearchRequest(this, request)) {
          this.uiFlags.contact = {
            ...this.uiFlags.contact,
            isFetching: false,
          };
        }
      }
    },
    async conversationSearch(payload) {
      const { page = 1, ...searchParams } = payload;
      const request = currentSearchRequest(this);
      this.uiFlags.conversation = {
        ...this.uiFlags.conversation,
        isFetching: true,
      };
      try {
        const { data } = await SearchAPI.conversations({
          ...searchParams,
          page,
          signal: request.signal,
        });
        if (!isCurrentSearchRequest(this, request)) return;

        this.conversationRecords = [
          ...this.conversationRecords,
          ...data.payload.conversations,
        ];
      } catch (error) {
        // Ignore error
      } finally {
        if (isCurrentSearchRequest(this, request)) {
          this.uiFlags.conversation = {
            ...this.uiFlags.conversation,
            isFetching: false,
          };
        }
      }
    },
    async messageSearch(payload) {
      const { page = 1, ...searchParams } = payload;
      const request = currentSearchRequest(this);
      this.uiFlags.message = { ...this.uiFlags.message, isFetching: true };
      try {
        const { data } = await SearchAPI.messages({
          ...searchParams,
          page,
          signal: request.signal,
        });
        if (!isCurrentSearchRequest(this, request)) return;

        this.messageRecords = [
          ...this.messageRecords,
          ...data.payload.messages,
        ];
      } catch (error) {
        // Ignore error
      } finally {
        if (isCurrentSearchRequest(this, request)) {
          this.uiFlags.message = {
            ...this.uiFlags.message,
            isFetching: false,
          };
        }
      }
    },
    async articleSearch(payload) {
      const { page = 1, ...searchParams } = payload;
      const request = currentSearchRequest(this);
      this.uiFlags.article = { ...this.uiFlags.article, isFetching: true };
      try {
        const { data } = await SearchAPI.articles({
          ...searchParams,
          page,
          signal: request.signal,
        });
        if (!isCurrentSearchRequest(this, request)) return;

        this.articleRecords = [
          ...this.articleRecords,
          ...data.payload.articles,
        ];
      } catch (error) {
        // Ignore error
      } finally {
        if (isCurrentSearchRequest(this, request)) {
          this.uiFlags.article = {
            ...this.uiFlags.article,
            isFetching: false,
          };
        }
      }
    },
    clearSearchResults() {
      const scope = getSearchRequestScope(this);
      abortActiveSearch(this);
      scope.generation += 1;
      this.contactRecords = [];
      this.conversationRecords = [];
      this.messageRecords = [];
      this.articleRecords = [];
      this.uiFlags = createUIFlags();
    },
  },
});
