import { computed } from 'vue';
import { useStore, useStoreGetters } from 'dashboard/composables/store';

/**
 * Composable for managing conversation labels
 * @returns {Object} An object containing methods and computed properties for conversation labels
 */
export function useConversationLabels() {
  const store = useStore();
  const getters = useStoreGetters();

  /**
   * The currently selected chat
   * @type {import('vue').ComputedRef<Object>}
   */
  const currentChat = computed(() => getters.getSelectedChat.value);

  /**
   * The ID of the current conversation
   * @type {import('vue').ComputedRef<number|null>}
   */
  const conversationId = computed(() => currentChat.value?.id);
  const isCommunicationThread = computed(() =>
    Boolean(currentChat.value?.is_communication_thread)
  );

  /**
   * All labels available for the account
   * @type {import('vue').ComputedRef<Array>}
   */
  const accountLabels = computed(() => getters['labels/getLabels'].value);

  /**
   * Labels currently saved to the conversation
   * @type {import('vue').ComputedRef<Array>}
   */
  const savedLabels = computed(() => {
    return store.getters['conversationLabels/getConversationLabels'](
      conversationId.value
    );
  });

  /**
   * Labels currently active on the conversation
   * @type {import('vue').ComputedRef<Array>}
   */
  const activeLabels = computed(() =>
    accountLabels.value.filter(({ title }) => savedLabels.value.includes(title))
  );

  /**
   * Labels available but not active on the conversation
   * @type {import('vue').ComputedRef<Array>}
   */
  const inactiveLabels = computed(() =>
    accountLabels.value.filter(
      ({ title }) => !savedLabels.value.includes(title)
    )
  );

  /**
   * Updates the labels for the current conversation
   * @param {string[]} selectedLabels - Array of label titles to be set for the conversation
   * @returns {Promise<void>}
   */
  const onUpdateLabels = async selectedLabels => {
    await store.dispatch('conversationLabels/update', {
      conversationId: conversationId.value,
      isCommunicationThread: isCommunicationThread.value,
      labels: selectedLabels,
    });
  };

  /**
   * Adds a label to the current conversation. Only the change is sent, so a list that is out of date cannot erase labels.
   * @param {Object} value - The label object to be added
   * @param {string} value.title - The title of the label to be added
   */
  const addLabelToConversation = value => {
    store.dispatch('conversationLabels/update', {
      conversationId: conversationId.value,
      isCommunicationThread: isCommunicationThread.value,
      add: [value.title],
    });
  };

  /**
   * Removes a label from the current conversation. Only the change is sent.
   * @param {string} value - The title of the label to be removed
   */
  const removeLabelFromConversation = value => {
    store.dispatch('conversationLabels/update', {
      conversationId: conversationId.value,
      isCommunicationThread: isCommunicationThread.value,
      remove: [value],
    });
  };

  return {
    accountLabels,
    savedLabels,
    activeLabels,
    inactiveLabels,
    addLabelToConversation,
    removeLabelFromConversation,
    onUpdateLabels,
  };
}
