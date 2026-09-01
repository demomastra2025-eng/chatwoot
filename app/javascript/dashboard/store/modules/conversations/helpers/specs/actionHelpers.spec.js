import {
  buildConversationList,
  isOnMentionsView,
  isOnFoldersView,
  isOnParticipatingView,
} from '../actionHelpers';
import types from '../../../../mutation-types';

describe('#isOnMentionsView', () => {
  it('return valid responses when passing the state', () => {
    expect(isOnMentionsView({ route: { name: 'conversation_mentions' } })).toBe(
      true
    );
    expect(isOnMentionsView({ route: { name: 'conversation_messages' } })).toBe(
      false
    );
  });
});

describe('#isOnFoldersView', () => {
  it('return valid responses when passing the state', () => {
    expect(isOnFoldersView({ route: { name: 'folder_conversations' } })).toBe(
      true
    );
    expect(
      isOnFoldersView({ route: { name: 'conversations_through_folders' } })
    ).toBe(true);
    expect(isOnFoldersView({ route: { name: 'conversation_messages' } })).toBe(
      false
    );
  });
});

describe('#isOnParticipatingView', () => {
  it('return valid responses when passing the state', () => {
    expect(
      isOnParticipatingView({ route: { name: 'conversation_participating' } })
    ).toBe(true);
    expect(
      isOnParticipatingView({
        route: { name: 'conversation_through_participating' },
      })
    ).toBe(true);
    expect(
      isOnParticipatingView({ route: { name: 'conversation_messages' } })
    ).toBe(false);
  });
});

describe('#buildConversationList', () => {
  it('keeps scoped list metadata out of global sidebar counters', () => {
    const context = {
      commit: vi.fn(),
      dispatch: vi.fn(),
    };

    buildConversationList(
      context,
      { page: 1 },
      {
        payload: [],
        meta: {
          all_count: 7,
          mine_count: 2,
          unread_counts: { all: 4 },
        },
      },
      'scope:label:vip',
      true,
      false
    );

    expect(context.dispatch).toHaveBeenCalledWith(
      'conversationPage/setTotalCount',
      { filter: 'scope:label:vip', count: 7 }
    );
    expect(context.dispatch).not.toHaveBeenCalledWith(
      'conversationStats/set',
      expect.anything()
    );
    expect(context.commit).not.toHaveBeenCalledWith(
      types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS,
      expect.anything()
    );
  });
});
