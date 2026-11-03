import { onBeforeUnmount, ref, watch } from 'vue';
import CrmTasksAPI from 'dashboard/api/crm/tasks';
import { normalizePayload } from 'dashboard/stores/crm/shared';

// List snapshots and timeline windows do not carry actor-specific access.
// Resolve the source once per opened task through its authorized detail API.
export const useCrmTaskConversation = ({ accountId, task }) => {
  const conversation = ref(null);
  let generation = 0;
  let identity = '';

  watch(
    [accountId, task, () => task.value?.originatingConversationId],
    async () => {
      const account = Number(accountId.value);
      const taskId = task.value?.id;
      const originId = task.value?.originatingConversationId;
      const nextIdentity = [account, taskId, originId].join(':');
      const hasDetail = Object.hasOwn(
        task.value || {},
        'originatingConversation'
      );
      // An index/broadcast snapshot omits this actor-specific detail field.
      if (identity === nextIdentity && !hasDetail) return;
      identity = nextIdentity;
      generation += 1;
      const requestGeneration = generation;
      conversation.value = null;
      if (!taskId || !originId || Number(task.value?.accountId) !== account) {
        return;
      }

      const applyReference = detail => {
        const reference = detail.originatingConversation;
        if (
          Number(detail.id) === Number(taskId) &&
          Number(detail.accountId) === account &&
          reference &&
          Number(reference.id) === Number(detail.originatingConversationId) &&
          Number(reference.accountId) === account
        ) {
          conversation.value = reference;
        }
      };
      if (hasDetail) {
        applyReference(task.value);
        return;
      }

      try {
        const { data } = await CrmTasksAPI.show(taskId);
        if (requestGeneration !== generation) return;
        applyReference(normalizePayload(data));
      } catch {
        // Missing, denied or failed detail reads leave the source as text.
      }
    },
    { immediate: true, flush: 'sync' }
  );

  onBeforeUnmount(() => {
    generation += 1;
  });

  return { conversation };
};
