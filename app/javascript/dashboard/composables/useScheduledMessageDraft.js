import { readonly, ref } from 'vue';

const scheduledMessageDraft = ref(null);
const DRAFT_TTL_MS = 2 * 60 * 1000;

export const setScheduledMessageDraft = draft => {
  scheduledMessageDraft.value = { ...draft, createdAt: Date.now() };
};

export const useScheduledMessageDraft = () => readonly(scheduledMessageDraft);

export const consumeScheduledMessageDraft = context => {
  const draft = scheduledMessageDraft.value;
  if (!draft) return null;
  scheduledMessageDraft.value = null;

  if (Date.now() - draft.createdAt > DRAFT_TTL_MS) return null;

  const matchesContext =
    String(draft.accountId) === String(context.accountId) &&
    String(draft.conversationId) === String(context.conversationId) &&
    String(draft.remindableId) === String(context.remindableId) &&
    draft.remindableType === context.remindableType;

  return matchesContext ? draft : null;
};

export const clearScheduledMessageDraft = () => {
  scheduledMessageDraft.value = null;
};
