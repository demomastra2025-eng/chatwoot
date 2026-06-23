import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';

const normalizePositiveNumber = value => {
  const numberValue = Number(value);
  return Number.isFinite(numberValue) && numberValue > 0 ? numberValue : null;
};

const resolveReferenceId = chat =>
  chat?.display_id || chat?.displayId || chat?.id || '';

const formatReferenceDisplayId = referenceId => {
  return referenceId ? `#${referenceId}` : '';
};

export const resolveChatContact = chat => {
  const sender = chat?.meta?.sender;
  if (sender?.id) return sender;

  const contactId = chat?.contact_id || chat?.contactId;
  return contactId ? { id: contactId } : {};
};

export const resolveChatContactId = chat =>
  normalizePositiveNumber(resolveChatContact(chat)?.id);

export const buildCrmDealSourceContext = chat => {
  const referenceId = resolveReferenceId(chat);
  const communicationThread = isCommunicationThread(chat);
  const contact = resolveChatContact(chat);
  const contactId = normalizePositiveNumber(contact?.id);

  return {
    contact,
    contactId,
    sourceType: communicationThread ? 'communication_thread' : 'conversation',
    originatingConversationDisplayId: communicationThread
      ? ''
      : formatReferenceDisplayId(referenceId),
    originatingConversationId: communicationThread ? '' : referenceId,
    originatingCommunicationThreadDisplayId: communicationThread
      ? formatReferenceDisplayId(referenceId)
      : '',
    originatingCommunicationThreadId: communicationThread ? referenceId : '',
  };
};

export const buildCrmDealOriginLookupParams = context => {
  if (context?.originatingCommunicationThreadId) {
    return {
      originating_communication_thread_id:
        context.originatingCommunicationThreadId,
    };
  }

  if (context?.originatingConversationId) {
    return { originating_conversation_id: context.originatingConversationId };
  }

  return null;
};

export const buildCrmDealLookupParams = context => {
  if (context?.contactId) {
    return { contact_id: context.contactId };
  }

  return buildCrmDealOriginLookupParams(context);
};

export const mergeUniqueCrmDeals = (...dealCollections) => {
  const uniqueDealsById = new Map();

  dealCollections.flat().forEach(deal => {
    if (!deal?.id) return;

    uniqueDealsById.set(String(deal.id), deal);
  });

  return [...uniqueDealsById.values()];
};

const dealContactIds = deal =>
  [
    deal?.primaryContactId,
    ...(deal?.dealContacts || []).map(contact => contact.contactId),
  ]
    .map(normalizePositiveNumber)
    .filter(Boolean);

export const dealMatchesCrmDealSourceContext = (deal, context) => {
  if (!deal || !context) return false;

  if (
    context.contactId &&
    dealContactIds(deal).includes(Number(context.contactId))
  ) {
    return true;
  }

  if (context.originatingCommunicationThreadId) {
    const threadReference =
      deal.originatingCommunicationThreadDisplayId ??
      deal.originatingCommunicationThreadId;
    return (
      Number(threadReference) ===
      Number(context.originatingCommunicationThreadId)
    );
  }

  if (context.originatingConversationId) {
    const conversationReference =
      deal.originatingConversationDisplayId ?? deal.originatingConversationId;
    return (
      Number(conversationReference) ===
      Number(context.originatingConversationId)
    );
  }

  return false;
};

const sourceMatchScore = (deal, context) => {
  if (
    context?.originatingCommunicationThreadId &&
    Number(
      deal?.originatingCommunicationThreadDisplayId ??
        deal?.originatingCommunicationThreadId
    ) === Number(context.originatingCommunicationThreadId)
  ) {
    return 40;
  }

  if (
    context?.originatingConversationId &&
    Number(
      deal?.originatingConversationDisplayId ?? deal?.originatingConversationId
    ) === Number(context.originatingConversationId)
  ) {
    return 30;
  }

  return 0;
};

const dealTimestamp = deal =>
  Date.parse(deal?.updatedAt || deal?.createdAt || 0) || 0;

export const sortCrmDealsForContext = (deals = [], context = {}) => {
  return deals
    .filter(deal => dealMatchesCrmDealSourceContext(deal, context))
    .sort((left, right) => {
      const sourceScoreDiff =
        sourceMatchScore(right, context) - sourceMatchScore(left, context);
      if (sourceScoreDiff !== 0) return sourceScoreDiff;

      const openScoreDiff = Number(!right.closedAt) - Number(!left.closedAt);
      if (openScoreDiff !== 0) return openScoreDiff;

      return dealTimestamp(right) - dealTimestamp(left);
    });
};

export const selectBestCrmDealForContext = (deals = [], context = {}) =>
  sortCrmDealsForContext(deals, context)[0] || null;
