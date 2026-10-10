import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';

export const DELETION_KIND = 'conversation_deletion';
export const MAX_DELETION_OPERATIONS = 100;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const validDeletionId = value =>
  (typeof value === 'number' ||
    (typeof value === 'string' && /^\d+$/.test(value))) &&
  Number.isSafeInteger(Number(value)) &&
  Number(value) > 0;

export const deletionStorageKey = scope =>
  `conversation-deletions:${scope.accountId}:${scope.userId}`;
export const deletionEventStorageKey = scope =>
  `conversation-deletion-events:${scope.accountId}:${scope.userId}`;
export const sameDeletionScope = (a, b) =>
  !!a && !!b && a.accountId === b.accountId && a.userId === b.userId;
export const deletionOutcome = operation => {
  const statuses = operation.targets.map(target => target.status);
  if (statuses.includes('pending')) return 'pending';
  if (statuses.every(status => status === 'deleted')) return 'deleted';
  return statuses.includes('deleted') ? 'partial' : 'failed';
};

export const latestDeletionOutcome = operations => {
  const targets = new Map();
  operations.forEach(operation => {
    operation.targets.forEach(target => targets.set(String(target.id), target));
  });
  return targets.size
    ? deletionOutcome({ targets: [...targets.values()] })
    : null;
};

// The receipt contains only operation/target identities and states. Never store
// conversation snapshots: a failed deletion must reload the current server row.
export const validateDeletionOperation = operation => {
  if (
    !operation ||
    typeof operation.requestKey !== 'string' ||
    !UUID.test(operation.requestKey)
  )
    return false;
  if (operation.operationId !== null && !validDeletionId(operation.operationId))
    return false;
  if (operation.threadId !== null && !validDeletionId(operation.threadId))
    return false;
  return (
    Array.isArray(operation.targets) &&
    operation.targets.length > 0 &&
    operation.targets.length <= 100 &&
    operation.targets.every(
      target =>
        validDeletionId(target.id) &&
        ['pending', 'deleted', 'failed'].includes(target.status)
    ) &&
    new Set(operation.targets.map(target => Number(target.id))).size ===
      operation.targets.length
  );
};

export const deletionReceipt = (run, operation) => {
  const metadata = run?.metadata;
  if (
    run?.resource_type !== 'Conversation' ||
    run.action_name !== 'delete' ||
    metadata?.operation_kind !== DELETION_KIND ||
    metadata.request_key !== operation.requestKey ||
    !validDeletionId(run.id) ||
    (operation.operationId && Number(run.id) !== operation.operationId) ||
    (metadata.selection?.thread_id !== null &&
      !validDeletionId(metadata.selection?.thread_id)) ||
    Number(metadata.selection?.thread_id || 0) !==
      Number(operation.threadId || 0)
  )
    return null;
  const expected = operation.targets
    .map(target => target.id)
    .sort((a, b) => a - b);
  const selected = metadata.selection?.conversation_ids;
  if (
    !Array.isArray(selected) ||
    !selected.every(validDeletionId) ||
    JSON.stringify([...selected].sort((a, b) => a - b)) !==
      JSON.stringify(expected)
  )
    return null;
  const targets = (Array.isArray(metadata.targets) ? metadata.targets : []).map(
    target => ({
      id: target.conversation_id,
      status: target.status,
    })
  );
  const next = { ...operation, operationId: Number(run.id), targets };
  if (
    !validateDeletionOperation(next) ||
    JSON.stringify(targets.map(target => target.id).sort((a, b) => a - b)) !==
      JSON.stringify(expected)
  )
    return null;
  // A late queued response cannot resurrect a terminal target.
  next.targets = targets.map(target => {
    const previous = operation.targets.find(item => item.id === target.id);
    return previous.status === 'pending' ? target : previous;
  });
  return next;
};

export const blockedDeletionIds = state =>
  new Set(
    [
      ...(state.deletionObservedIds || []),
      ...(state.deletionOperations || []).flatMap(operation =>
        operation.targets
          .filter(target => target.status !== 'failed')
          .map(target => String(target.id))
      ),
    ].map(String)
  );

export const retainDeletionOperations = operations => {
  const retained = [...operations];
  while (retained.length > MAX_DELETION_OPERATIONS) {
    const index = retained.findIndex(
      operation => deletionOutcome(operation) !== 'pending'
    );
    if (index < 0) break;
    retained.splice(index, 1);
  }
  return retained;
};

// After old receipts are compacted, an absent row/channel from a late event
// needs a fresh server read before it can be reintroduced. New IDs remain valid.
export const requiresDeletionAuthority = (state, conversation) => {
  if (!state.deletionOperations?.length && !state.deletionObservedIds?.length)
    return false;
  const threaded = isCommunicationThread(conversation);
  const existing = state.allConversations.find(
    row =>
      String(row.id) === String(conversation.id) &&
      isCommunicationThread(row) === threaded
  );
  if (!existing) return true;
  if (!threaded) return false;
  const ids = [
    ...(conversation.conversation_ids || []),
    ...(conversation.channels || []).map(channel => channel.conversation_id),
    conversation.conversation_id,
    conversation.message?.conversation_id,
    conversation.last_non_activity_message?.conversation_id,
    conversation.last_message?.conversation_id,
    ...(conversation.messages || []).map(message => message.conversation_id),
  ].filter(validDeletionId);
  const current = new Set(
    (existing.channels || []).map(channel => String(channel.conversation_id))
  );
  return ids.some(id => !current.has(String(id)));
};

export const projectDeletedConversation = (conversation, blocked) => {
  if (!blocked.size) return conversation;
  if (!isCommunicationThread(conversation))
    return blocked.has(String(conversation.id)) ? null : conversation;
  const channels = conversation.channels?.filter(
    channel => !blocked.has(String(channel.conversation_id))
  );
  // A realtime patch may omit channels. The final merged row is projected again.
  if (channels && conversation.channels.length > 0 && !channels.length)
    return null;
  return {
    ...conversation,
    ...(blocked.has(String(conversation.conversation_id))
      ? { conversation_id: null }
      : {}),
    ...(blocked.has(String(conversation.message?.conversation_id))
      ? { message: null, message_id: null }
      : {}),
    ...(blocked.has(
      String(conversation.last_non_activity_message?.conversation_id)
    )
      ? { last_non_activity_message: null }
      : {}),
    ...(blocked.has(String(conversation.last_message?.conversation_id))
      ? { last_message: null }
      : {}),
    ...(channels ? { channels } : {}),
    ...(conversation.conversation_ids
      ? {
          conversation_ids: conversation.conversation_ids.filter(
            id => !blocked.has(String(id))
          ),
        }
      : {}),
    ...(conversation.messages
      ? {
          messages: conversation.messages.filter(
            message => !blocked.has(String(message.conversation_id))
          ),
        }
      : {}),
  };
};

export const readDeletionOperations = scope => {
  try {
    const entries = JSON.parse(
      localStorage.getItem(deletionStorageKey(scope)) || '[]'
    );
    return Array.isArray(entries)
      ? retainDeletionOperations(
          entries.filter(validateDeletionOperation).map(entry => ({
            requestKey: entry.requestKey.toLowerCase(),
            operationId:
              entry.operationId === null ? null : Number(entry.operationId),
            threadId: entry.threadId === null ? null : Number(entry.threadId),
            targets: entry.targets.map(target => ({
              id: Number(target.id),
              status: target.status,
            })),
          }))
        )
      : [];
  } catch {
    return [];
  }
};
export const persistDeletionOperations = (scope, operations) => {
  try {
    localStorage.setItem(deletionStorageKey(scope), JSON.stringify(operations));
  } catch {
    // Browser storage may be unavailable. The current session remains guarded.
  }
};

export const readDeletionEventIds = scope => {
  try {
    const ids = JSON.parse(
      localStorage.getItem(deletionEventStorageKey(scope)) || '[]'
    );
    return Array.isArray(ids)
      ? [...new Set(ids.filter(validDeletionId).map(Number))].slice(-10000)
      : [];
  } catch {
    return [];
  }
};
export const persistDeletionEventIds = (scope, ids) => {
  try {
    localStorage.setItem(deletionEventStorageKey(scope), JSON.stringify(ids));
  } catch {
    // The in-memory guard remains active if browser storage is unavailable.
  }
};
