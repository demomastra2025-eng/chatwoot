import types from '../../../mutation-types';
import { mutations } from '../../conversationWatchers';

describe('#mutations', () => {
  describe('#SET_CONVERSATION_PARTICIPANTS', () => {
    it('sets an individual record', () => {
      let state = {
        records: {},
      };

      mutations[types.SET_CONVERSATION_PARTICIPANTS](state, {
        data: [],
        conversationId: 1,
      });
      expect(state.records).toEqual({ 'conversation:1': [] });
    });

    it('isolates legacy conversation and communication thread records with the same display id', () => {
      let state = {
        records: {},
      };

      mutations[types.SET_CONVERSATION_PARTICIPANTS](state, {
        data: [{ id: 1 }],
        conversationId: 1,
      });
      mutations[types.SET_CONVERSATION_PARTICIPANTS](state, {
        data: [{ id: 2 }],
        conversationId: 1,
        communicationThreadMode: true,
      });

      expect(state.records).toEqual({
        'conversation:1': [{ id: 1 }],
        'thread:1': [{ id: 2 }],
      });
    });
  });

  describe('#SET_CONVERSATION_PARTICIPANTS_UI_FLAG', () => {
    it('set ui flags', () => {
      let state = {
        uiFlags: {
          isFetching: true,
          isUpdating: false,
        },
      };

      mutations[types.SET_CONVERSATION_PARTICIPANTS_UI_FLAG](state, {
        isFetching: false,
      });
      expect(state.uiFlags).toEqual({
        isFetching: false,
        isUpdating: false,
      });
    });
  });
});
