import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store.js';
import { useBulkActions } from '../useBulkActions';
import { useConversationRequiredAttributes } from 'dashboard/composables/useConversationRequiredAttributes';
import BulkActionsAPI from 'dashboard/api/bulkActions';
import mutationTypes from 'dashboard/store/mutation-types';

vi.mock('vuex');
vi.mock('vue-i18n');
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));
vi.mock('dashboard/composables/store.js');
vi.mock('dashboard/composables/useConversationRequiredAttributes');
vi.mock('dashboard/api/bulkActions', () => ({
  default: { selectAll: vi.fn() },
}));

describe('useBulkActions', () => {
  let store;

  beforeEach(() => {
    BulkActionsAPI.selectAll.mockReset();
    store = {
      dispatch: vi.fn(async () => ({})),
      commit: vi.fn(),
      getters: {
        'bulkActions/getSelectedConversationIds': [1, 2],
        getConversationById: vi.fn(),
      },
    };

    useStore.mockReturnValue(store);
    useMapGetter.mockImplementation(key => ({
      value: store.getters[key],
    }));
    useI18n.mockReturnValue({ t: vi.fn(key => key) });
    useConversationRequiredAttributes.mockReturnValue({
      checkMissingAttributes: vi.fn(() => ({ hasMissing: false })),
    });
    useAlert.mockImplementation(() => {});
  });

  it('removes only one inbox occurrence when deselecting a conversation from the same inbox', () => {
    const { selectedInboxes, selectConversation, deSelectConversation } =
      useBulkActions();

    selectConversation(1, 10);
    selectConversation(2, 10);
    deSelectConversation(1, 10);

    expect(selectedInboxes.value).toEqual([10]);
    expect(store.dispatch).toHaveBeenLastCalledWith(
      'bulkActions/removeSelectedConversationIds',
      1
    );
  });

  it('selects all inboxes from communication thread channels', () => {
    const { selectedInboxes, selectAllConversations } = useBulkActions();

    selectAllConversations(true, [
      {
        id: 7,
        is_communication_thread: true,
        channels: [{ inbox_id: 10 }, { inbox_id: 20 }, { inbox_id: null }],
      },
      {
        id: 8,
        is_communication_thread: true,
        channels: [{ inbox_id: 30 }],
      },
    ]);

    expect(selectedInboxes.value).toEqual([10, 20, 30]);
    expect(store.dispatch).toHaveBeenLastCalledWith(
      'bulkActions/setSelectedConversationIds',
      [7, 8]
    );
  });

  it('updates selected conversations locally after bulk status change', async () => {
    const { onUpdateConversations } = useBulkActions();

    await onUpdateConversations('resolved', null);

    expect(store.dispatch).toHaveBeenNthCalledWith(1, 'bulkActions/process', {
      type: 'Conversation',
      ids: [1, 2],
      fields: {
        status: 'resolved',
      },
      snoozed_until: null,
    });
    expect(store.commit.mock.calls).toEqual([
      [
        mutationTypes.CHANGE_CONVERSATION_STATUS,
        {
          conversationId: 1,
          status: 'resolved',
          snoozedUntil: null,
          conversationType: 'conversation',
        },
      ],
      [
        mutationTypes.CHANGE_CONVERSATION_STATUS,
        {
          conversationId: 2,
          status: 'resolved',
          snoozedUntil: null,
          conversationType: 'conversation',
        },
      ],
    ]);
    expect(store.dispatch).toHaveBeenNthCalledWith(
      2,
      'bulkActions/clearSelectedConversationIds'
    );
  });

  it('uses communication thread payloads for thread bulk status updates', async () => {
    const { onUpdateConversations } = useBulkActions();

    await onUpdateConversations('resolved', null, true);

    expect(store.dispatch).toHaveBeenNthCalledWith(1, 'bulkActions/process', {
      type: 'CommunicationThread',
      ids: [1, 2],
      fields: {
        status: 'resolved',
      },
      snoozed_until: null,
    });
    expect(store.getters.getConversationById).toHaveBeenCalledWith(
      1,
      'communication_thread'
    );
    expect(store.commit.mock.calls).toEqual([
      [
        mutationTypes.CHANGE_CONVERSATION_STATUS,
        {
          conversationId: 1,
          status: 'resolved',
          snoozedUntil: null,
          conversationType: 'communication_thread',
        },
      ],
      [
        mutationTypes.CHANGE_CONVERSATION_STATUS,
        {
          conversationId: 2,
          status: 'resolved',
          snoozedUntil: null,
          conversationType: 'communication_thread',
        },
      ],
    ]);
  });

  it('uses communication thread payloads for thread bulk mark read', async () => {
    const { onMarkConversationsRead } = useBulkActions();

    await onMarkConversationsRead(true);

    expect(store.dispatch).toHaveBeenNthCalledWith(1, 'bulkActions/process', {
      type: 'CommunicationThread',
      ids: [1, 2],
      action_name: 'mark_read',
    });
    expect(store.commit.mock.calls).toEqual([
      [
        mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT,
        expect.objectContaining({
          id: 1,
          unreadCount: 0,
          conversationType: 'communication_thread',
        }),
      ],
      [
        mutationTypes.UPDATE_MESSAGE_UNREAD_COUNT,
        expect.objectContaining({
          id: 2,
          unreadCount: 0,
          conversationType: 'communication_thread',
        }),
      ],
    ]);
  });

  it('reports how many conversations failed when a bulk run fails', async () => {
    useAlert.mockClear();
    const failure = new Error('Bulk action failed');
    failure.failedCount = 3;
    store.dispatch = vi.fn(async type => {
      if (type === 'bulkActions/process') throw failure;
      return {};
    });
    const { onUpdateConversations } = useBulkActions();

    await onUpdateConversations('resolved', null, true);

    expect(useAlert).toHaveBeenCalledWith('BULK_ACTION.PROGRESS.FAILED');
    expect(useI18n().t).toHaveBeenCalledWith('BULK_ACTION.PROGRESS.FAILED', {
      count: 3,
    });
  });

  it('falls back to the generic failure text without a failed count', async () => {
    useAlert.mockClear();
    store.dispatch = vi.fn(async type => {
      if (type === 'bulkActions/process') throw new Error('network');
      return {};
    });
    const { onMarkConversationsRead } = useBulkActions();

    await onMarkConversationsRead(true);

    expect(useAlert).toHaveBeenCalledWith('BULK_ACTION.MARK_READ.FAILED');
  });

  it('does not report a completed run with skipped conversations as a full success', async () => {
    useAlert.mockClear();
    store.dispatch = vi.fn(async type =>
      type === 'bulkActions/process'
        ? { status: 'completed', failed_count: 0, skipped_count: 2 }
        : {}
    );
    const { onAssignTeamsForBulk } = useBulkActions();

    await onAssignTeamsForBulk({ id: 5 }, true);

    expect(useAlert).toHaveBeenCalledWith('BULK_ACTION.COMPLETED_WITH_DETAILS');
    expect(useI18n().t).toHaveBeenCalledWith(
      'BULK_ACTION.COMPLETED_WITH_DETAILS',
      { failedCount: 0, skippedCount: 2 }
    );
  });

  it('reports both partial failures and permission skips from the completed run', async () => {
    useAlert.mockClear();
    store.dispatch = vi.fn(async type =>
      type === 'bulkActions/process'
        ? { status: 'completed', failed_count: 1, skipped_count: 2 }
        : {}
    );
    const { onAssignTeamsForBulk } = useBulkActions();

    await onAssignTeamsForBulk({ id: 5 }, true);

    expect(useI18n().t).toHaveBeenCalledWith(
      'BULK_ACTION.COMPLETED_WITH_DETAILS',
      { failedCount: 1, skippedCount: 2 }
    );
  });

  it('keeps the success text for a completed run without failures', async () => {
    useAlert.mockClear();
    store.dispatch = vi.fn(async type =>
      type === 'bulkActions/process'
        ? { status: 'completed', failed_count: 0 }
        : {}
    );
    const { onAssignTeamsForBulk } = useBulkActions();

    await onAssignTeamsForBulk({ id: 5 }, true);

    expect(useAlert).toHaveBeenCalledWith('BULK_ACTION.TEAMS.ASSIGN_SUCCESFUL');
  });

  it('reports an unknown result without claiming the action failed', async () => {
    const statusUnknown = Object.assign(new Error('Status unavailable'), {
      code: 'bulk_action_status_unknown',
    });
    store.dispatch = vi.fn(async action => {
      if (action === 'bulkActions/process') throw statusUnknown;
      return {};
    });
    const { onUpdateConversations } = useBulkActions();

    await onUpdateConversations('snoozed', 12345);

    expect(useAlert).toHaveBeenCalledWith(
      'BULK_ACTION.PROGRESS.STATUS_UNAVAILABLE'
    );
  });

  it.each(['Conversation', 'CommunicationThread'])(
    'uses a signed bounded snapshot for all matching %s rows',
    async type => {
      BulkActionsAPI.selectAll.mockResolvedValue({
        data: {
          payload: {
            token: 'signed-selection-token',
            count: 3,
            ids: [1, 2, 3],
            inbox_ids: [10, 20],
            inbox_ids_by_id: { 1: [10], 2: [20], 3: [10] },
          },
        },
      });
      const actions = useBulkActions();
      const filters = {
        mode: 'advanced',
        query_data: {
          payload: [{ attribute_key: 'status', values: ['open'] }],
        },
        crm_pipeline_id: 4,
        crm_stage_id: 8,
        appointment_status: 'confirmed',
        unread: true,
      };

      await actions.selectAllMatching(
        filters,
        type,
        'account-1:advanced-folder-7'
      );

      expect(BulkActionsAPI.selectAll).toHaveBeenCalledWith(type, filters);
      expect(actions.selectedCount.value).toBe(3);
      expect(actions.selectedInboxes.value).toEqual([10, 20]);
      expect(actions.isConversationSelected(2)).toBe(true);
      // New rows matching after the snapshot are not visually selected.
      expect(actions.isConversationSelected(4)).toBe(false);

      await actions.onAssignTeamsForBulk(
        { id: 5 },
        type === 'CommunicationThread'
      );
      expect(store.dispatch).toHaveBeenCalledWith('bulkActions/process', {
        type,
        selection_token: 'signed-selection-token',
        excluded_ids: [],
        fields: { team_id: 5 },
      });
    }
  );

  it('excludes a manually deselected snapshot row from the token payload and inboxes', async () => {
    BulkActionsAPI.selectAll.mockResolvedValue({
      data: {
        payload: {
          token: 'signed-selection-token',
          count: 3,
          ids: [1, 2, 3],
          inbox_ids_by_id: { 1: [10], 2: [20], 3: [30] },
        },
      },
    });
    const actions = useBulkActions();
    await actions.selectAllMatching({ inbox_id: 10 }, 'Conversation', 'ctx');

    actions.deSelectConversation(2, 20);

    expect(actions.selectedCount.value).toBe(2);
    expect(store.dispatch).toHaveBeenCalledWith(
      'bulkActions/setAllMatchingSelectionCount',
      2
    );
    expect(actions.selectedInboxes.value).toEqual([10, 30]);
    expect(actions.isConversationSelected(2)).toBe(false);
    actions.deSelectConversation(2, 20);
    expect(actions.allMatchingSelection.value.excludedIds).toEqual([2]);
    expect(actions.selectedCount.value).toBe(2);

    actions.selectConversation(2, 20);
    expect(actions.isConversationSelected(2)).toBe(true);
    expect(actions.selectedCount.value).toBe(3);
    expect(store.dispatch).toHaveBeenCalledWith(
      'bulkActions/setAllMatchingSelectionCount',
      3
    );
    expect(actions.selectedInboxes.value).toEqual([10, 20, 30]);

    actions.deSelectConversation(2, 20);
    await actions.onAssignTeamsForBulk({ id: 5 });

    expect(store.dispatch).toHaveBeenCalledWith('bulkActions/process', {
      type: 'Conversation',
      selection_token: 'signed-selection-token',
      excluded_ids: [2],
      fields: { team_id: 5 },
    });
  });

  it('sends snapshot snooze through the token payload with current exclusions', async () => {
    BulkActionsAPI.selectAll.mockResolvedValue({
      data: {
        payload: {
          token: 'signed-selection-token',
          count: 3,
          ids: [1, 2, 3],
          inbox_ids_by_id: { 1: [10], 2: [20], 3: [30] },
        },
      },
    });
    const actions = useBulkActions();
    await actions.selectAllMatching({ status: 'open' }, 'Conversation', 'ctx');
    actions.deSelectConversation(2, 20);

    await actions.onUpdateConversations('snoozed', 12345);

    expect(store.dispatch).toHaveBeenCalledWith('bulkActions/process', {
      type: 'Conversation',
      selection_token: 'signed-selection-token',
      excluded_ids: [2],
      fields: { status: 'snoozed' },
      snoozed_until: 12345,
    });
  });

  it('ignores a deferred snapshot response after its filter context changes', async () => {
    let resolveSnapshot;
    BulkActionsAPI.selectAll.mockReturnValue(
      new Promise(resolve => {
        resolveSnapshot = resolve;
      })
    );
    const actions = useBulkActions();
    actions.setSelectionContext('folder-1');
    const request = actions.selectAllMatching(
      { mode: 'advanced', query_data: { payload: [] } },
      'Conversation',
      'folder-1'
    );

    actions.setSelectionContext('folder-2');
    resolveSnapshot({
      data: {
        payload: {
          token: 'stale-token',
          count: 1,
          ids: [9],
          inbox_ids_by_id: { 9: [90] },
        },
      },
    });

    await expect(request).resolves.toBeNull();
    expect(actions.allMatchingSelection.value).toBeNull();
    expect(actions.isSelectingAll.value).toBe(false);
    expect(actions.selectedInboxes.value).toEqual([]);
  });

  it('clears an expired snapshot and shows the reselect message on the real API error shape', async () => {
    BulkActionsAPI.selectAll.mockResolvedValue({
      data: {
        payload: {
          token: 'expired-token',
          count: 2,
          ids: [1, 2],
          inbox_ids_by_id: { 1: [10], 2: [20] },
        },
      },
    });
    store.getters['bulkActions/getSelectedConversationIds'] = [];
    const expiredError = Object.assign(new Error('selection invalid'), {
      response: { data: { error: { code: 'selection_invalid' } } },
    });
    store.dispatch = vi.fn(async type => {
      if (type === 'bulkActions/process') {
        throw expiredError;
      }
      return {};
    });
    const actions = useBulkActions();
    await actions.selectAllMatching({ status: 'open' }, 'Conversation', 'ctx');
    useAlert.mockClear();

    await actions.onMarkConversationsRead();

    expect(actions.allMatchingSelection.value).toBeNull();
    expect(actions.selectedCount.value).toBe(0);
    expect(useAlert).toHaveBeenCalledWith('BULK_ACTION.SELECT_ALL.EXPIRED');
    expect(store.dispatch).toHaveBeenCalledWith(
      'bulkActions/clearSelectedConversationIds'
    );
    expect(
      store.dispatch.mock.calls.filter(
        ([action]) => action === 'bulkActions/process'
      )
    ).toHaveLength(1);
  });
});
