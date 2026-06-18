import types from '../../../mutation-types';
import { mutations } from '../../conversationStats';

describe('#mutations', () => {
  describe('#SET_CONV_TAB_META', () => {
    it('set conversation stats correctly', () => {
      const state = {};
      mutations[types.SET_CONV_TAB_META](state, {
        mine_count: 1,
        unassigned_count: 1,
        assigned_count: 1,
        all_count: 2,
        assignee_counts: {
          mine_count: 4,
          assigned_count: 7,
          unassigned_count: 3,
          all_count: 10,
        },
      });
      expect(state).toEqual({
        mineCount: 1,
        unAssignedCount: 1,
        allCount: 2,
        assigneeCounts: {
          mine: 4,
          assigned: 7,
          unassigned: 3,
          all: 10,
        },
        mineUnreadCount: 0,
        unAssignedUnreadCount: 0,
        assignedUnreadCount: 0,
        allUnreadCount: 0,
        updatedOn: expect.any(Date),
      });
    });
  });
});
