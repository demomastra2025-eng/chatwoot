import BulkActionsAPI from 'dashboard/api/bulkActions';
import ConversationAPI from 'dashboard/api/inbox/conversation';
import CommunicationThreadAPI from 'dashboard/api/inbox/communicationThread';
import types from '../../../mutation-types';
import { buildCommunicationThreadConversation } from 'dashboard/helper/communicationThreadHelper';
import {
  deletionOutcome,
  deletionReceipt,
  sameDeletionScope,
  readDeletionOperations,
  persistDeletionOperations,
  validDeletionId,
  MAX_DELETION_OPERATIONS,
  readDeletionEventIds,
  persistDeletionEventIds,
} from '../helpers/deletionState';

const activePolls = new Map();
const scopeFor = context => ({
  accountId: String(BulkActionsAPI.captureContext().accountId || ''),
  userId: String(context.rootGetters.getCurrentUser?.id || ''),
});
const isCurrent = (context, scope) =>
  sameDeletionScope(scopeFor(context), scope) &&
  sameDeletionScope(context.state.deletionScope, scope) &&
  context.state.deletionScope.generation === scope.generation;
const matchesExpectedScope = (context, expected) =>
  !expected ||
  (validDeletionId(expected.accountId) &&
    validDeletionId(expected.userId) &&
    sameDeletionScope(scopeFor(context), {
      accountId: String(expected.accountId),
      userId: String(expected.userId),
    }));

const save = (context, scope, operation) => {
  if (!isCurrent(context, scope)) return null;
  const previous = context.state.deletionOperations.find(
    entry => entry.requestKey === operation.requestKey
  );
  if (previous) {
    operation = {
      ...operation,
      operationId: operation.operationId || previous.operationId,
      targets: operation.targets.map(target => {
        const current = previous.targets.find(item => item.id === target.id);
        return current && current.status !== 'pending' ? current : target;
      }),
    };
    if (JSON.stringify(previous) === JSON.stringify(operation)) return previous;
  }
  context.commit(types.SET_CONVERSATION_DELETION_OPERATION, operation);
  persistDeletionOperations(scope, context.state.deletionOperations);
  if (
    deletionOutcome(operation) !== 'pending' &&
    (!previous || deletionOutcome(previous) === 'pending')
  ) {
    context.dispatch('invalidateConversationListRequests');
    context.dispatch(
      'conversationStats/get',
      {
        communicationThreadMode:
          context.state.conversationFilters?.communicationThreadMode ??
          Boolean(operation.threadId),
      },
      { root: true }
    );
    context.dispatch('fetchSidebarUnreadCounts');
  }
  return operation;
};

// Polls are sequential so one operation never has overlapping status requests.
/* eslint-disable no-await-in-loop */
const poll = async (context, scope, initial, apiContext) => {
  let operation = initial;
  const deadline = Date.now() + 15000;
  for (let attempt = 0; attempt < 20 && Date.now() < deadline; attempt += 1) {
    if (!isCurrent(context, scope)) return { outcome: 'scope_changed' };
    operation =
      context.state.deletionOperations.find(
        entry => entry.requestKey === operation.requestKey
      ) || operation;
    if (deletionOutcome(operation) !== 'pending') break;
    try {
      const response = operation.operationId
        ? await BulkActionsAPI.show(operation.operationId, apiContext, {
            timeout: 5000,
          })
        : await BulkActionsAPI.findDeletion(operation.requestKey, apiContext);
      if (!isCurrent(context, scope)) return { outcome: 'scope_changed' };
      const next = deletionReceipt(response.data?.payload, operation);
      if (next) {
        operation = save(context, scope, next) || next;
      }
    } catch {
      // A timeout/lost response is still pending. GET never starts deletion.
    }
    if (deletionOutcome(operation) === 'pending')
      await new Promise(resolve => setTimeout(resolve, 750));
  }
  operation =
    context.state.deletionOperations.find(
      entry => entry.requestKey === operation.requestKey
    ) || operation;
  if (
    isCurrent(context, scope) &&
    ['failed', 'partial'].includes(deletionOutcome(operation))
  )
    await context.dispatch('reconcileFailedConversationDeletion', {
      scope,
      operation,
      apiContext,
    });
  return isCurrent(context, scope)
    ? { outcome: deletionOutcome(operation), operation }
    : { outcome: 'scope_changed' };
};
/* eslint-enable no-await-in-loop */

const reconcile = (context, scope, operation, apiContext) => {
  const key = `${scope.accountId}:${scope.userId}:${scope.generation}:${operation.requestKey}`;
  if (activePolls.has(key)) return activePolls.get(key);
  const promise = poll(context, scope, operation, apiContext).finally(() =>
    activePolls.delete(key)
  );
  activePolls.set(key, promise);
  return promise;
};

const submit = async (context, scope, operation, apiContext) => {
  context.dispatch('invalidateConversationListRequests');
  save(context, scope, operation);
  const ids = operation.targets.map(target => target.id);
  try {
    const response =
      operation.threadId === null
        ? await ConversationAPI.delete(ids[0], operation.requestKey, apiContext)
        : await CommunicationThreadAPI.deleteConversations(
            operation.threadId,
            ids,
            operation.requestKey,
            apiContext
          );
    if (!isCurrent(context, scope)) return { outcome: 'scope_changed' };
    operation = deletionReceipt(response.data?.payload, operation) || operation;
    operation = save(context, scope, operation) || operation;
  } catch (error) {
    if (!isCurrent(context, scope)) return { outcome: 'scope_changed' };
    const receipt = deletionReceipt(error.response?.data?.payload, operation);
    if (receipt) operation = receipt;
    else if ([400, 401, 403, 404, 409, 422].includes(error.response?.status))
      operation = {
        ...operation,
        targets: ids.map(id => ({ id, status: 'failed' })),
      };
    operation = save(context, scope, operation) || operation;
  }
  return reconcile(context, scope, operation, apiContext);
};

const remove = async (
  context,
  { conversationIds, threadId = null, expectedScope }
) => {
  if (
    !Array.isArray(conversationIds) ||
    !conversationIds.length ||
    conversationIds.length > 100 ||
    !conversationIds.every(validDeletionId) ||
    new Set(conversationIds.map(Number)).size !== conversationIds.length ||
    (threadId !== null && !validDeletionId(threadId))
  )
    throw new Error('Invalid deletion target');
  if (!matchesExpectedScope(context, expectedScope))
    return { outcome: 'scope_changed' };
  let scope = scopeFor(context);
  if (!scope.accountId || !scope.userId)
    throw new Error('Missing deletion scope');
  const apiContext = BulkActionsAPI.captureContext();
  const previousScope = context.state.deletionScope;
  await context.dispatch('initializeConversationDeletions');
  if (!matchesExpectedScope(context, expectedScope))
    return { outcome: 'scope_changed' };
  if (!sameDeletionScope(scopeFor(context), scope))
    return { outcome: 'scope_changed' };
  if (
    sameDeletionScope(previousScope, scope) &&
    previousScope !== context.state.deletionScope
  )
    return { outcome: 'scope_changed' };
  scope = context.state.deletionScope;
  const ids = [...new Set(conversationIds.map(Number))].sort((a, b) => a - b);
  const current = context.state.deletionOperations.find(
    entry =>
      deletionOutcome(entry) === 'pending' &&
      entry.threadId === (threadId === null ? null : Number(threadId)) &&
      JSON.stringify(entry.targets.map(target => target.id)) ===
        JSON.stringify(ids)
  );
  if (current) return reconcile(context, scope, current, apiContext);
  if (
    context.state.deletionOperations.filter(
      entry => deletionOutcome(entry) === 'pending'
    ).length >= MAX_DELETION_OPERATIONS
  )
    throw new Error('Pending deletion limit reached');
  const operation = {
    requestKey: crypto.randomUUID(),
    operationId: null,
    threadId: threadId === null ? null : Number(threadId),
    targets: ids.map(id => ({ id, status: 'pending' })),
  };
  return submit(context, scope, operation, apiContext);
};

export default {
  async observeConversationDeletion(context, payload) {
    const requestedScope = scopeFor(context);
    if (
      !validDeletionId(payload?.id) ||
      !validDeletionId(payload?.account_id) ||
      String(payload.account_id) !== requestedScope.accountId
    )
      return;
    await context.dispatch('initializeConversationDeletions');
    const scope = context.state.deletionScope;
    if (!sameDeletionScope(requestedScope, scope) || !isCurrent(context, scope))
      return;
    context.dispatch('invalidateConversationListRequests');
    context.commit(
      types.REGISTER_CONVERSATION_DELETION_EVENT,
      Number(payload.id)
    );
    persistDeletionEventIds(scope, context.state.deletionObservedIds);
    context.dispatch(
      'conversationStats/get',
      {
        communicationThreadMode: Boolean(
          context.state.conversationFilters?.communicationThreadMode
        ),
      },
      { root: true }
    );
    context.dispatch('fetchSidebarUnreadCounts');
  },
  async reconcileFailedConversationDeletion(
    context,
    { scope, operation, apiContext }
  ) {
    const targets = operation.threadId
      ? [operation.threadId]
      : operation.targets
          .filter(target => target.status === 'failed')
          .map(target => target.id);
    await Promise.all(
      targets.map(async id => {
        try {
          const api = operation.threadId
            ? CommunicationThreadAPI
            : ConversationAPI;
          const response = await api.show(id, apiContext, { timeout: 5000 });
          if (
            !isCurrent(context, scope) ||
            !validDeletionId(response.data?.id) ||
            Number(response.data.id) !== id
          )
            return;
          const mode =
            context.state.conversationFilters?.communicationThreadMode;
          if (typeof mode === 'boolean' && mode !== Boolean(operation.threadId))
            return;
          const conversation = operation.threadId
            ? buildCommunicationThreadConversation(response.data)
            : response.data;
          context.commit(
            types.SET_CONVERSATION_DELETION_AUTHORITY,
            conversation
          );
        } catch {
          // The native list refresh still runs. Never restore an old snapshot.
        }
      })
    );
  },
  initializeConversationDeletions(context) {
    const scope = scopeFor(context);
    if (sameDeletionScope(context.state.deletionScope, scope)) return;
    context.dispatch('invalidateConversationListRequests');
    context.commit(types.SET_CONVERSATION_DELETION_SCOPE, {
      scope: {
        ...scope,
        generation: (context.state.deletionScope?.generation || 0) + 1,
      },
      operations:
        scope.accountId && scope.userId ? readDeletionOperations(scope) : [],
      observedIds:
        scope.accountId && scope.userId ? readDeletionEventIds(scope) : [],
    });
  },
  async reconcileConversationDeletions(context) {
    await context.dispatch('initializeConversationDeletions');
    const scope = context.state.deletionScope;
    const apiContext = BulkActionsAPI.captureContext();
    return Promise.all(
      context.state.deletionOperations
        .filter(operation => deletionOutcome(operation) === 'pending')
        .map(operation => reconcile(context, scope, operation, apiContext))
    );
  },
  // Only the explicit confirmation dialog invokes this action. Polling and
  // reopening the list never retry a destructive request.
  async retryUnacknowledgedConversationDeletion(context, request) {
    const { requestKey, expectedScope } =
      typeof request === 'string' ? { requestKey: request } : request;
    if (!matchesExpectedScope(context, expectedScope))
      return { outcome: 'scope_changed' };
    const requestedScope = scopeFor(context);
    const previousScope = context.state.deletionScope;
    await context.dispatch('initializeConversationDeletions');
    if (
      !matchesExpectedScope(context, expectedScope) ||
      !sameDeletionScope(requestedScope, scopeFor(context)) ||
      (sameDeletionScope(previousScope, requestedScope) &&
        previousScope !== context.state.deletionScope)
    )
      return { outcome: 'scope_changed' };
    const scope = context.state.deletionScope;
    const entry = context.state.deletionOperations.find(
      operation => operation.requestKey === requestKey
    );
    if (!entry) return { outcome: 'scope_changed' };
    if (entry.operationId || deletionOutcome(entry) !== 'pending')
      return reconcile(context, scope, entry, BulkActionsAPI.captureContext());
    return submit(context, scope, entry, BulkActionsAPI.captureContext());
  },
  deleteConversation: (context, request) => {
    const { conversationId, expectedScope } =
      request && typeof request === 'object' && !Array.isArray(request)
        ? request
        : { conversationId: request };
    return remove(context, {
      conversationIds: [conversationId],
      expectedScope,
    });
  },
  deleteCommunicationThreadConversations: (
    context,
    { threadId, conversationIds, expectedScope }
  ) => remove(context, { threadId, conversationIds, expectedScope }),
};
