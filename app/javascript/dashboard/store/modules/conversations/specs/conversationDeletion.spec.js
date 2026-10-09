import actions from '../actions';
import { mutations } from '../index';
import types from '../../../mutation-types';
import BulkActionsAPI from 'dashboard/api/bulkActions';
import ConversationAPI from 'dashboard/api/inbox/conversation';
import CommunicationThreadAPI from 'dashboard/api/inbox/communicationThread';
import {
  deletionOutcome,
  deletionReceipt,
  deletionStorageKey,
  deletionEventStorageKey,
  retainDeletionOperations,
  requiresDeletionAuthority,
  readDeletionOperations,
  validDeletionId,
} from '../helpers/deletionState';

const KEY = 'a5e8a276-5ad2-4b7e-a3f6-4a5ca7d7fc1c';
const plain = (id = 12, text = 'old') => ({
  id,
  inbox_id: 1,
  meta: { sender: { id: 9 } },
  messages: [{ id: 1, content: text }],
});
const thread = (ids = [12, 13]) => ({
  id: 7,
  is_communication_thread: true,
  channels: ids.map(id => ({
    conversation_id: id,
    inbox_id: id,
    can_reply: true,
  })),
  conversation_ids: ids,
  messages: ids.map(id => ({ id, conversation_id: id })),
  meta: { sender: { id: 9 } },
});
const operation = (statuses = ['pending'], threadId = null) => ({
  requestKey: KEY,
  operationId: 91,
  threadId,
  targets: statuses.map((status, index) => ({ id: index + 12, status })),
});
const receipt = (
  entry,
  statuses = entry.targets.map(target => target.status)
) => ({
  id: 91,
  resource_type: 'Conversation',
  action_name: 'delete',
  status: statuses.includes('pending') ? 'queued' : 'completed',
  metadata: {
    operation_kind: 'conversation_deletion',
    request_key: entry.requestKey,
    selection: {
      conversation_ids: entry.targets.map(target => target.id),
      thread_id: entry.threadId,
    },
    targets: entry.targets.map((target, index) => ({
      conversation_id: target.id,
      record_id: target.id + 1000,
      status: statuses[index],
    })),
  },
});

let accountId;
const contextFor = () => {
  const state = {
    allConversations: [plain(), thread()],
    deletionScope: null,
    deletionOperations: [],
    selectedChatId: null,
    selectedChatType: null,
    appliedFilters: [],
    conversationFilters: {},
  };
  state.syncConversationsMessages = {};
  const context = {
    state,
    rootState: { route: {} },
    rootGetters: { getCurrentUser: { id: 8 } },
  };
  context.commit = vi.fn((type, payload) => mutations[type]?.(state, payload));
  context.dispatch = vi.fn((type, payload) => {
    if (
      [
        'initializeConversationDeletions',
        'invalidateConversationListRequests',
        'reconcileFailedConversationDeletion',
      ].includes(type)
    )
      return actions[type](context, payload);
    return Promise.resolve();
  });
  return context;
};

describe('durable conversation deletion', () => {
  beforeEach(() => {
    accountId = '74';
    localStorage.clear();
    vi.useFakeTimers();
    vi.spyOn(BulkActionsAPI, 'captureContext').mockImplementation(() => ({
      accountId,
      baseUrl: `/api/v1/accounts/${accountId}`,
    }));
    vi.spyOn(BulkActionsAPI, 'isContextCurrent').mockImplementation(
      context => context.accountId === accountId
    );
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it('shows pending after acceptance and returns success only after the per-target receipt', async () => {
    const context = contextFor();
    vi.spyOn(ConversationAPI, 'delete').mockImplementation(() =>
      Promise.resolve({
        data: { payload: receipt(context.state.deletionOperations[0]) },
      })
    );
    vi.spyOn(BulkActionsAPI, 'show')
      .mockImplementationOnce(() =>
        Promise.resolve({
          data: { payload: receipt(context.state.deletionOperations[0]) },
        })
      )
      .mockImplementationOnce(() =>
        Promise.resolve({
          data: {
            payload: receipt(context.state.deletionOperations[0], ['deleted']),
          },
        })
      );
    const request = actions.deleteConversation(context, 12);
    await vi.advanceTimersByTimeAsync(0);
    expect(deletionOutcome(context.state.deletionOperations[0])).toBe(
      'pending'
    );
    expect(
      context.state.allConversations.some(
        row => !row.is_communication_thread && row.id === 12
      )
    ).toBe(false);
    expect(context.commit).not.toHaveBeenCalledWith(
      types.DELETE_CONVERSATION,
      12
    );
    await vi.runAllTimersAsync();
    expect((await request).outcome).toBe('deleted');
    expect(ConversationAPI.delete).toHaveBeenCalledWith(
      12,
      expect.any(String),
      { accountId: '74', baseUrl: '/api/v1/accounts/74' }
    );
    expect(BulkActionsAPI.show).toHaveBeenCalledWith(91, expect.any(Object), {
      timeout: 5000,
    });
  });

  it('keeps queue backlog honest after the bounded polling budget', async () => {
    const context = contextFor();
    vi.spyOn(ConversationAPI, 'delete').mockImplementation(() =>
      Promise.resolve({
        data: { payload: receipt(context.state.deletionOperations[0]) },
      })
    );
    vi.spyOn(BulkActionsAPI, 'show').mockImplementation(() =>
      Promise.resolve({
        data: { payload: receipt(context.state.deletionOperations[0]) },
      })
    );
    const request = actions.deleteConversation(context, 12);
    await vi.advanceTimersByTimeAsync(0);
    await vi.runAllTimersAsync();
    expect((await request).outcome).toBe('pending');
    expect(BulkActionsAPI.show.mock.calls.length).toBeLessThanOrEqual(20);
    expect(deletionOutcome(context.state.deletionOperations[0])).toBe(
      'pending'
    );
    expect(context.dispatch).not.toHaveBeenCalledWith(
      'conversationStats/get',
      {},
      { root: true }
    );
  });

  it('recovers a lost DELETE response through readonly key lookup without a destructive retry', async () => {
    const context = contextFor();
    vi.spyOn(ConversationAPI, 'delete').mockRejectedValue(
      new Error('network response lost')
    );
    vi.spyOn(BulkActionsAPI, 'findDeletion').mockImplementation(() =>
      Promise.resolve({
        data: {
          payload: receipt(context.state.deletionOperations[0], ['deleted']),
        },
      })
    );
    expect((await actions.deleteConversation(context, 12)).outcome).toBe(
      'deleted'
    );
    expect(ConversationAPI.delete).toHaveBeenCalledTimes(1);
    expect(BulkActionsAPI.findDeletion).toHaveBeenCalledWith(
      context.state.deletionOperations[0].requestKey,
      expect.any(Object)
    );
    const persisted = localStorage.getItem(
      deletionStorageKey(context.state.deletionScope)
    );
    expect(persisted).not.toMatch(/record_id|sender|messages|content|phone/);
  });

  it('repeats an unacknowledged request only through the explicit action using the same UUID and exact targets', async () => {
    const context = contextFor();
    actions.initializeConversationDeletions(context);
    const entry = { ...operation(), operationId: null };
    context.commit(types.SET_CONVERSATION_DELETION_OPERATION, entry);
    vi.spyOn(ConversationAPI, 'delete').mockResolvedValue({
      data: { payload: receipt(entry, ['deleted']) },
    });
    const result = await actions.retryUnacknowledgedConversationDeletion(
      context,
      KEY
    );
    expect(result.outcome).toBe('deleted');
    expect(ConversationAPI.delete).toHaveBeenCalledWith(12, KEY, {
      accountId: '74',
      baseUrl: '/api/v1/accounts/74',
    });
    expect(context.state.deletionOperations).toHaveLength(1);
  });

  it('reopens a saved pending operation with readonly reconciliation and no DELETE', async () => {
    const context = contextFor();
    const entry = operation();
    localStorage.setItem(
      deletionStorageKey({ accountId: '74', userId: '8' }),
      JSON.stringify([entry])
    );
    vi.spyOn(ConversationAPI, 'delete');
    vi.spyOn(BulkActionsAPI, 'show').mockResolvedValue({
      data: { payload: receipt(entry, ['deleted']) },
    });
    const results = await actions.reconcileConversationDeletions(context);
    expect(results[0].outcome).toBe('deleted');
    expect(ConversationAPI.delete).not.toHaveBeenCalled();
  });

  it('reports failed enqueue and reloads authority instead of restoring a stale snapshot', async () => {
    const context = contextFor();
    vi.spyOn(ConversationAPI, 'delete').mockImplementation(() =>
      Promise.reject({
        response: {
          status: 503,
          data: {
            payload: receipt(context.state.deletionOperations[0], ['failed']),
          },
        },
      })
    );
    vi.spyOn(BulkActionsAPI, 'show');
    vi.spyOn(ConversationAPI, 'show').mockResolvedValue({
      data: plain(12, 'new server content'),
    });
    expect((await actions.deleteConversation(context, 12)).outcome).toBe(
      'failed'
    );
    expect(BulkActionsAPI.show).not.toHaveBeenCalled();
    expect(context.dispatch).toHaveBeenCalledWith(
      'invalidateConversationListRequests'
    );
    expect(ConversationAPI.show).toHaveBeenCalledWith(
      12,
      { accountId: '74', baseUrl: '/api/v1/accounts/74' },
      { timeout: 5000 }
    );
    const restored = context.state.allConversations.find(
      row => !row.is_communication_thread && row.id === 12
    );
    expect(restored.messages[0].content).toBe('new server content');
  });

  it('retains per-target partial outcomes and preserves unselected/new channels and typed rows', async () => {
    const context = contextFor();
    vi.spyOn(CommunicationThreadAPI, 'deleteConversations').mockImplementation(
      () =>
        Promise.resolve({
          data: {
            payload: receipt(context.state.deletionOperations[0], [
              'deleted',
              'failed',
            ]),
          },
        })
    );
    vi.spyOn(CommunicationThreadAPI, 'show').mockResolvedValue({
      data: thread([12, 13, 14]),
    });
    const result = await actions.deleteCommunicationThreadConversations(
      context,
      { threadId: 7, conversationIds: [12, 13] }
    );
    expect(result.outcome).toBe('partial');
    expect(CommunicationThreadAPI.show).toHaveBeenCalledWith(
      7,
      expect.any(Object),
      { timeout: 5000 }
    );
    expect(
      context.state.allConversations
        .find(row => row.is_communication_thread)
        .messages.map(message => message.conversation_id)
    ).toEqual([13, 14]);
    expect(CommunicationThreadAPI.deleteConversations).toHaveBeenCalledWith(
      7,
      [12, 13],
      expect.any(String),
      expect.any(Object)
    );
    context.commit(types.REPLACE_ALL_CONVERSATION, [
      thread([12, 13, 14]),
      plain(7),
      plain(15),
    ]);
    expect(
      context.state.allConversations.find(row => row.is_communication_thread)
        .conversation_ids
    ).toEqual([13, 14]);
    expect(
      context.state.allConversations
        .filter(row => !row.is_communication_thread)
        .map(row => row.id)
    ).toEqual([7, 15]);
  });

  it('suppresses stale HTTP/WS rows and deleted-channel messages while allowing a new conversation ID', () => {
    const context = contextFor();
    actions.initializeConversationDeletions(context);
    context.commit(
      types.SET_CONVERSATION_DELETION_OPERATION,
      operation(['deleted'])
    );
    for (const type of [
      types.SET_ALL_CONVERSATION,
      types.REPLACE_ALL_CONVERSATION,
    ])
      context.commit(type, [plain(), thread()]);
    context.commit(types.ADD_CONVERSATION, plain());
    context.commit(types.UPDATE_CONVERSATION, plain());
    context.commit(types.UPDATE_CONVERSATION, { ...thread(), updated_at: 5 });
    context.commit(types.ADD_MESSAGE_TO_CHAT, {
      chatId: 7,
      message: { id: 22, conversation_id: 12, inbox_id: 12 },
    });
    context.commit(types.ADD_CONVERSATION, plain(16));
    expect(
      context.state.allConversations.find(row => row.is_communication_thread)
        .conversation_ids
    ).toEqual([13]);
    expect(
      context.state.allConversations
        .find(row => row.is_communication_thread)
        .messages.some(message => message.conversation_id === 12)
    ).toBe(false);
    expect(
      context.state.allConversations
        .filter(row => !row.is_communication_thread)
        .map(row => row.id)
    ).toEqual([16]);
  });

  it('does not apply a delayed response after account/user switch, including switch back', async () => {
    const context = contextFor();
    let finish;
    let original;
    vi.spyOn(ConversationAPI, 'delete').mockImplementation(() => {
      original = context.state.deletionOperations[0];
      return new Promise(resolve => {
        finish = resolve;
      });
    });
    const request = actions.deleteConversation(context, 12);
    await vi.advanceTimersByTimeAsync(0);
    accountId = '75';
    actions.initializeConversationDeletions(context);
    context.commit(types.REPLACE_ALL_CONVERSATION, [plain()]);
    expect(context.state.allConversations).toHaveLength(1);
    accountId = '74';
    context.rootGetters.getCurrentUser = { id: 9 };
    actions.initializeConversationDeletions(context);
    context.rootGetters.getCurrentUser = { id: 8 };
    actions.initializeConversationDeletions(context);
    finish({ data: { payload: receipt(original, ['deleted']) } });
    expect((await request).outcome).toBe('scope_changed');
    expect(deletionOutcome(context.state.deletionOperations[0])).toBe(
      'pending'
    );
  });

  it('bounds stored terminal receipts and confirms absent realtime rows before reintroduction', async () => {
    const context = contextFor();
    actions.initializeConversationDeletions(context);
    context.state.deletionOperations = retainDeletionOperations(
      Array.from({ length: 101 }, (_, index) => ({
        ...operation(['deleted']),
        requestKey: `${index}`,
        targets: [{ id: index + 100, status: 'deleted' }],
      }))
    );
    expect(context.state.deletionOperations).toHaveLength(100);
    expect(requiresDeletionAuthority(context.state, plain(100))).toBe(true);
    vi.spyOn(ConversationAPI, 'show')
      .mockRejectedValueOnce({ response: { status: 404 } })
      .mockResolvedValueOnce({ data: plain(10001, 'new inbound') });
    await actions.addConversation(context, plain(100));
    expect(context.state.allConversations.some(row => row.id === 100)).toBe(
      false
    );
    await actions.addConversation(context, plain(10001));
    expect(context.state.allConversations.some(row => row.id === 10001)).toBe(
      true
    );
  });

  it('rejects mismatched kind/key/target receipts and keeps terminal outcomes monotonic', () => {
    const entry = operation(['deleted']);
    expect(
      deletionReceipt(receipt(entry, ['pending']), entry).targets[0].status
    ).toBe('deleted');
    const wrong = receipt(entry);
    wrong.metadata.selection.conversation_ids = [13];
    expect(deletionReceipt(wrong, entry)).toBeNull();
    wrong.metadata.operation_kind = 'contact_deletion';
    expect(deletionReceipt(wrong, entry)).toBeNull();
  });

  it('rejects arrays/objects/duplicates at admission, receipt and stored identity boundaries', async () => {
    const context = contextFor();
    vi.spyOn(ConversationAPI, 'delete');
    await Promise.all(
      [[12], { id: 12 }, '12e1', 1.5, true].map(async value => {
        expect(validDeletionId(value)).toBe(false);
        await expect(
          actions.deleteConversation(context, value)
        ).rejects.toThrow('Invalid deletion target');
      })
    );
    expect(ConversationAPI.delete).not.toHaveBeenCalled();
    for (const ids of [[12, '12'], [[12]], { id: 12 }]) {
      await expect(
        actions.deleteCommunicationThreadConversations(context, {
          threadId: 7,
          conversationIds: ids,
        })
      ).rejects.toThrow('Invalid deletion target');
    }
    const malformed = {
      ...operation(),
      targets: [{ id: [12], status: 'pending' }],
    };
    const storage = deletionStorageKey({ accountId: '74', userId: '8' });
    localStorage.setItem(
      storage,
      JSON.stringify([
        malformed,
        { ...operation(), threadId: { id: 7 } },
        {
          ...operation(),
          targets: [
            { id: 12, status: 'pending' },
            { id: '12', status: 'pending' },
          ],
        },
      ])
    );
    expect(readDeletionOperations({ accountId: '74', userId: '8' })).toEqual(
      []
    );
    const invalidReceipt = receipt(operation());
    invalidReceipt.metadata.targets[0].conversation_id = [12];
    expect(deletionReceipt(invalidReceipt, operation())).toBeNull();
    const invalidThread = receipt(operation(['pending'], 7));
    invalidThread.metadata.selection.thread_id = [7];
    expect(
      deletionReceipt(invalidThread, operation(['pending'], 7))
    ).toBeNull();
  });

  it('keeps an unrelated empty thread when projecting another deleted identity', () => {
    const context = contextFor();
    actions.initializeConversationDeletions(context);
    context.commit(
      types.SET_CONVERSATION_DELETION_OPERATION,
      operation(['deleted'])
    );
    context.commit(types.REPLACE_ALL_CONVERSATION, [{ ...thread([]), id: 99 }]);
    expect(context.state.allConversations).toHaveLength(1);
  });

  it('removes a deleted child from native scalar/message previews and reply context while preserving the surviving thread', () => {
    const context = contextFor();
    actions.initializeConversationDeletions(context);
    context.commit(
      types.SET_CONVERSATION_DELETION_OPERATION,
      operation(['deleted'], 7)
    );
    context.commit(types.UPDATE_CONVERSATION, {
      ...thread(),
      conversation_id: 12,
      message_id: 22,
      message: { id: 22, conversation_id: 12, inbox_id: 12 },
      last_non_activity_message: { id: 22, conversation_id: 12, inbox_id: 12 },
      last_message: { id: 22, conversation_id: 12, inbox_id: 12 },
      updated_at: 5,
    });
    const surviving = context.state.allConversations.find(
      row => row.is_communication_thread
    );
    expect(surviving.id).toBe(7);
    expect(surviving.conversation_id).toBeNull();
    expect(surviving.message).toBeNull();
    expect(surviving.message_id).toBeNull();
    expect(surviving.last_non_activity_message).toBeNull();
    expect(surviving.last_message).toBeNull();
    expect(surviving.active_reply_channel_conversation_id).toBe(13);
    expect(surviving.inbox_id).toBe(13);
  });

  it('checks canonical shared-thread state before adding an absent child from a message-only event after compaction', async () => {
    const context = contextFor();
    actions.initializeConversationDeletions(context);
    context.state.deletionOperations = [operation(['deleted'])];
    context.state.allConversations = [thread([13])];
    vi.spyOn(CommunicationThreadAPI, 'show').mockResolvedValue({
      data: thread([13]),
    });
    await actions.updateCommunicationThreadRealtime(context, {
      id: 7,
      communication_thread_id: 7,
      message: {
        id: 200,
        conversation_id: 100,
        communication_thread_id: 7,
        inbox_id: 100,
      },
    });
    expect(CommunicationThreadAPI.show).toHaveBeenCalledWith(
      7,
      expect.any(Object),
      { timeout: 5000 }
    );
    expect(context.state.allConversations[0].conversation_ids).toEqual([13]);
    expect(
      context.state.allConversations[0].messages.some(
        message => message.conversation_id === 100
      )
    ).toBe(false);
  });

  it('applies a recipient deletion event without an actor operation and rejects stale HTTP/WS while allowing a new ID', async () => {
    const context = contextFor();
    actions.initializeConversationDeletions(context);
    let finish;
    vi.spyOn(ConversationAPI, 'show')
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            finish = resolve;
          })
      )
      .mockRejectedValueOnce({ response: { status: 404 } })
      .mockResolvedValueOnce({ data: plain(16, 'new inbound') });
    const oldDetail = actions.getConversation(context, 12);
    await actions.observeConversationDeletion(context, {
      account_id: 74,
      id: 12,
    });
    finish({ data: plain(12, 'obsolete response') });
    expect(await oldDetail).toBeNull();
    expect(context.state.deletionOperations).toEqual([]);
    expect(context.state.deletionObservedIds).toEqual([12]);
    context.commit(types.REPLACE_ALL_CONVERSATION, [
      plain(12),
      thread(),
      plain(7),
    ]);
    context.commit(types.ADD_MESSAGE_TO_CHAT, {
      chatId: 7,
      message: { id: 22, conversation_id: 12 },
    });
    await actions.addConversation(context, plain(12, 'obsolete event'));
    await actions.addConversation(context, plain(16, 'new inbound'));
    const surviving = context.state.allConversations.find(
      row => row.is_communication_thread
    );
    expect(surviving.conversation_ids).toEqual([13]);
    expect(
      surviving.messages.every(message => message.conversation_id === 13)
    ).toBe(true);
    expect(
      context.state.allConversations
        .filter(row => !row.is_communication_thread)
        .map(row => row.id)
    ).toEqual([7, 16]);
    expect(
      localStorage.getItem(deletionEventStorageKey(context.state.deletionScope))
    ).toBe('[12]');
  });

  it('keeps recipient tombstones typed and scoped to the captured account and employee', async () => {
    const context = contextFor();
    await actions.observeConversationDeletion(context, {
      account_id: 75,
      id: 12,
    });
    await actions.observeConversationDeletion(context, {
      account_id: [74],
      id: 12,
    });
    await actions.observeConversationDeletion(context, {
      account_id: 74,
      id: [12],
    });
    expect(
      context.state.allConversations.some(
        row => !row.is_communication_thread && row.id === 12
      )
    ).toBe(true);
    await actions.observeConversationDeletion(context, {
      account_id: 74,
      id: 12,
    });
    accountId = '75';
    actions.initializeConversationDeletions(context);
    context.commit(types.REPLACE_ALL_CONVERSATION, [plain(12)]);
    expect(context.state.allConversations).toHaveLength(1);
    accountId = '74';
    context.rootGetters.getCurrentUser = { id: 9 };
    actions.initializeConversationDeletions(context);
    context.commit(types.REPLACE_ALL_CONVERSATION, [plain(12)]);
    expect(context.state.allConversations).toHaveLength(1);
    context.rootGetters.getCurrentUser = { id: 8 };
    actions.initializeConversationDeletions(context);
    expect(context.state.allConversations).toHaveLength(0);
  });

  it('rejects an old dialog origin at destructive admission even when the target ID exists in the new account', async () => {
    const context = contextFor();
    vi.spyOn(ConversationAPI, 'delete');
    vi.spyOn(CommunicationThreadAPI, 'deleteConversations');
    const expectedScope = { accountId: '74', userId: '8' };
    accountId = '75';
    expect(
      (
        await actions.deleteConversation(context, {
          conversationId: 12,
          expectedScope,
        })
      ).outcome
    ).toBe('scope_changed');
    expect(
      (
        await actions.deleteCommunicationThreadConversations(context, {
          threadId: 7,
          conversationIds: [12],
          expectedScope,
        })
      ).outcome
    ).toBe('scope_changed');
    expect(
      (
        await actions.retryUnacknowledgedConversationDeletion(context, {
          requestKey: KEY,
          expectedScope,
        })
      ).outcome
    ).toBe('scope_changed');
    expect(ConversationAPI.delete).not.toHaveBeenCalled();
    expect(CommunicationThreadAPI.deleteConversations).not.toHaveBeenCalled();
  });

  it.each(['history', 'reconnect'])(
    'refreshes a deferred %s page after deletion and does not restore a deleted child through metadata or messages',
    async mode => {
      const context = contextFor();
      actions.initializeConversationDeletions(context);
      context.state.selectedChatId = 7;
      context.state.selectedChatType = 'communication_thread';
      let finish;
      vi.spyOn(CommunicationThreadAPI, 'messages')
        .mockImplementationOnce(
          () =>
            new Promise(resolve => {
              finish = resolve;
            })
        )
        .mockResolvedValueOnce({
          data: {
            meta: { channels: thread([13]).channels },
            payload: [{ id: 131, conversation_id: 13 }],
          },
        });
      const request =
        mode === 'history'
          ? actions.fetchPreviousMessages(context, {
              conversationId: 7,
              conversationType: 'communication_thread',
              before: 200,
            })
          : actions.syncActiveConversationMessages(context, {
              conversationId: 7,
              conversationType: 'communication_thread',
            });
      context.commit(
        types.SET_CONVERSATION_DELETION_OPERATION,
        operation(['pending'], 7)
      );
      finish({
        data: {
          meta: { channels: thread().channels },
          payload: [
            { id: 121, conversation_id: 12 },
            { id: 131, conversation_id: 13 },
          ],
        },
      });
      await request;
      expect(CommunicationThreadAPI.messages).toHaveBeenCalledTimes(2);
      const surviving = context.state.allConversations.find(
        row => row.is_communication_thread
      );
      expect(
        surviving.channels.map(channel => channel.conversation_id)
      ).toEqual([13]);
      expect(surviving.messages.map(message => message.id)).toContain(131);
      expect(
        surviving.messages.some(message => message.conversation_id === 12)
      ).toBe(false);
      expect(surviving.active_reply_channel_conversation_id).toBe(13);
      expect(context.commit).toHaveBeenCalledWith(
        `conversationMetadata/${types.SET_CONVERSATION_METADATA}`,
        {
          id: 7,
          data: { channels: thread([13]).channels },
        }
      );
      context.commit(types.SET_MISSING_MESSAGES, {
        id: 7,
        conversationType: 'communication_thread',
        data: thread().messages,
      });
      expect(
        context.state.allConversations
          .find(row => row.is_communication_thread)
          .messages.map(message => message.conversation_id)
      ).toEqual([13]);
    }
  );

  it('discards a deferred individual thread show after the deleted receipt was compacted', async () => {
    const context = contextFor();
    actions.initializeConversationDeletions(context);
    let finish;
    vi.spyOn(CommunicationThreadAPI, 'show').mockImplementation(
      () =>
        new Promise(resolve => {
          finish = resolve;
        })
    );
    const request = actions.getCommunicationThread(context, 7);
    context.commit(
      types.SET_CONVERSATION_DELETION_OPERATION,
      operation(['deleted'], 7)
    );
    context.state.deletionOperations = retainDeletionOperations(
      Array.from({ length: 101 }, (_, index) => ({
        ...operation(['deleted']),
        requestKey: String(index),
        targets: [{ id: index + 100, status: 'deleted' }],
      }))
    );
    finish({ data: thread() });
    expect(await request).toBeNull();
    expect(
      context.state.allConversations.find(row => row.is_communication_thread)
        .conversation_ids
    ).toEqual([13]);
  });

  it('discards a deferred history page after employee/account switch and switch back', async () => {
    const context = contextFor();
    actions.initializeConversationDeletions(context);
    let finish;
    vi.spyOn(CommunicationThreadAPI, 'messages').mockImplementation(
      () =>
        new Promise(resolve => {
          finish = resolve;
        })
    );
    const request = actions.fetchPreviousMessages(context, {
      conversationId: 7,
      conversationType: 'communication_thread',
    });
    accountId = '75';
    actions.initializeConversationDeletions(context);
    accountId = '74';
    actions.initializeConversationDeletions(context);
    context.commit.mockClear();
    finish({
      data: {
        meta: { channels: thread().channels },
        payload: [{ id: 300, conversation_id: 12 }],
      },
    });
    await request;
    expect(CommunicationThreadAPI.messages).toHaveBeenCalledTimes(1);
    expect(context.commit).not.toHaveBeenCalledWith(
      types.SET_PREVIOUS_CONVERSATIONS,
      expect.anything()
    );
  });
});
