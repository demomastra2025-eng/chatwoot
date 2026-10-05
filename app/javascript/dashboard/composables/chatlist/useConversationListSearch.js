import { computed, onBeforeUnmount, ref, unref, watch } from 'vue';
import { useStore } from 'vuex';

export const MIN_SERVER_SEARCH_LENGTH = 3;
export const SERVER_SEARCH_DELAY = 250;

// Search box of the conversation list. From MIN_SERVER_SEARCH_LENGTH characters the query is sent to the server, which
// looks through all statuses and all assignees whatever the list is filtered by: only the query and the page are
// sent, the list filters never are. Shorter queries are not searched on the server, the caller filters the loaded list
// instead. The list itself and its filters are not touched, so clearing the search brings the list back as it was.
export function useConversationListSearch({ query, communicationThreadMode }) {
  const store = useStore();
  const found = ref([]);
  const total = ref(0);
  const isCapped = ref(false);
  // The search of the message text ran out of time: the contacts and numbers are found, the text is incomplete.
  const isPartial = ref(false);
  const hasMore = ref(false);
  const isLoading = ref(false);
  const hasError = ref(false);
  let nextPage = 1;
  let requestId = 0;
  let timer = null;

  const trimmedQuery = computed(() => String(unref(query) || '').trim());
  const isActive = computed(
    () => trimmedQuery.value.length >= MIN_SERVER_SEARCH_LENGTH
  );
  const storeType = () =>
    unref(communicationThreadMode) ? 'communication_thread' : 'conversation';

  // Results are shown from the store copy, so realtime updates reach them, in the order the server returned.
  const results = computed(() =>
    found.value.map(
      chat => store.getters.getConversationById(chat.id, storeType()) || chat
    )
  );

  const reset = () => {
    clearTimeout(timer);
    requestId += 1;
    found.value = [];
    total.value = 0;
    isCapped.value = false;
    isPartial.value = false;
    hasMore.value = false;
    isLoading.value = false;
    hasError.value = false;
    nextPage = 1;
  };

  const fetchPage = async () => {
    requestId += 1;
    const currentRequest = requestId;
    const isFirstPage = nextPage === 1;
    isLoading.value = true;
    hasError.value = false;

    try {
      const { conversations, meta } = await store.dispatch(
        'fetchListSearchResults',
        {
          q: trimmedQuery.value,
          page: nextPage,
          communicationThreadMode: Boolean(unref(communicationThreadMode)),
        }
      );
      if (currentRequest !== requestId) return;

      found.value = isFirstPage
        ? conversations
        : [...found.value, ...conversations];
      total.value = Number(meta.total_count || 0);
      isCapped.value = Boolean(meta.capped);
      isPartial.value = Boolean(meta.partial);
      const perPage = Number(meta.per_page || conversations.length || 1);
      hasMore.value =
        conversations.length > 0 &&
        Number(meta.current_page || nextPage) * perPage < total.value;
      nextPage += 1;
    } catch (error) {
      if (currentRequest !== requestId) return;
      hasError.value = true;
    } finally {
      if (currentRequest === requestId) isLoading.value = false;
    }
  };

  const loadMore = ({ retry = false } = {}) => {
    if (
      !isActive.value ||
      isLoading.value ||
      !hasMore.value ||
      (hasError.value && !retry)
    ) {
      return;
    }
    fetchPage();
  };

  // A failed first page has nothing to continue from, so it is searched again from the start.
  const retry = () => {
    if (!isActive.value || isLoading.value) return;
    if (found.value.length) {
      loadMore({ retry: true });
      return;
    }
    nextPage = 1;
    fetchPage();
  };

  watch([trimmedQuery, () => unref(communicationThreadMode)], () => {
    reset();
    if (!isActive.value) return;

    // The previous list stays out of the way while the new results are on their way.
    isLoading.value = true;
    timer = setTimeout(fetchPage, SERVER_SEARCH_DELAY);
  });

  onBeforeUnmount(reset);

  return {
    isActive,
    results,
    total,
    isCapped,
    isPartial,
    hasMore,
    isLoading,
    hasError,
    loadMore,
    retry,
  };
}
