import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store.js';
import { useBulkActions } from '../useBulkActions';
import { useConversationRequiredAttributes } from 'dashboard/composables/useConversationRequiredAttributes';
import mutationTypes from 'dashboard/store/mutation-types';

vi.mock('vuex');
vi.mock('vue-i18n');
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));
vi.mock('dashboard/composables/store.js');
vi.mock('dashboard/composables/useConversationRequiredAttributes');

describe('useBulkActions', () => {
  let store;

  beforeEach(() => {
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
        { conversationId: 1, status: 'resolved', snoozedUntil: null },
      ],
      [
        mutationTypes.CHANGE_CONVERSATION_STATUS,
        { conversationId: 2, status: 'resolved', snoozedUntil: null },
      ],
    ]);
    expect(store.dispatch).toHaveBeenNthCalledWith(
      2,
      'bulkActions/clearSelectedConversationIds'
    );
  });
});
