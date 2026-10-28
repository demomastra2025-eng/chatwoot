import ConversationBox from './ConversationBox.vue';

describe('ConversationBox labels', () => {
  const labelTarget = currentChat =>
    ConversationBox.computed.currentChatLabelTarget.call({ currentChat });

  it('tells a thread and a conversation with the same id apart', () => {
    expect(labelTarget({ id: 7, is_communication_thread: true })).toBe(
      'communication_thread:7'
    );
    expect(labelTarget({ id: 7 })).toBe('conversation:7');
    expect(labelTarget({ id: 7 })).not.toBe(
      labelTarget({ id: 7, is_communication_thread: true })
    );
  });

  it('reloads the labels and resets the tab when the label target changes', () => {
    const context = { fetchLabels: vi.fn(), activeIndex: 2 };

    ConversationBox.watch.currentChatLabelTarget.call(
      context,
      'conversation:7',
      'communication_thread:7'
    );

    expect(context.fetchLabels).toHaveBeenCalledTimes(1);
    expect(context.activeIndex).toBe(0);
  });

  it('passes the payload labels of a channel conversation to the label store', () => {
    const dispatch = vi.fn();

    ConversationBox.methods.fetchLabels.call({
      currentChat: { id: 7, labels: ['vip'] },
      $store: { dispatch },
    });

    expect(dispatch).toHaveBeenCalledWith('conversationLabels/get', {
      conversationId: 7,
      isCommunicationThread: false,
      labels: ['vip'],
    });
  });

  it('asks the API for thread labels, which also hold the contact labels', () => {
    const dispatch = vi.fn();

    ConversationBox.methods.fetchLabels.call({
      currentChat: {
        id: 7,
        is_communication_thread: true,
        // A realtime thread update carries only the conversations' labels.
        labels: ['vip'],
      },
      $store: { dispatch },
    });

    expect(dispatch).toHaveBeenCalledWith('conversationLabels/get', {
      conversationId: 7,
      isCommunicationThread: true,
    });
    expect(dispatch.mock.calls[0][1]).not.toHaveProperty('labels');
  });

  it('does not load labels without an open chat', () => {
    const dispatch = vi.fn();

    ConversationBox.methods.fetchLabels.call({
      currentChat: {},
      $store: { dispatch },
    });

    expect(dispatch).not.toHaveBeenCalled();
  });

  it('skips re-fetching assignable agents and dashboard apps when already cached in store', () => {
    const dispatch = vi.fn();
    const context = {
      dashboardApps: [{ id: 1, title: 'App' }],
      fetchLabels: vi.fn(),
      $store: {
        state: {
          inboxAssignableAgents: {
            records: { 9: [{ id: 1, name: 'Agent' }] },
          },
        },
        getters: {
          'inboxAssignableAgents/getUIFlags': { isFetching: false },
          'dashboardApps/getUIFlags': { isFetching: false },
        },
        dispatch,
      },
    };

    ConversationBox.watch.currentChatReplyInboxId.handler.call(context, 9);
    ConversationBox.mounted.call(context);

    expect(dispatch).not.toHaveBeenCalledWith('inboxAssignableAgents/fetch', [
      9,
    ]);
    expect(dispatch).not.toHaveBeenCalledWith('dashboardApps/get');
  });

  it('does not request assignable agents for a deleted inbox', () => {
    const dispatch = vi.fn();
    ConversationBox.watch.currentChatReplyInboxId.handler.call(
      {
        $store: {
          getters: { 'inboxes/getInbox': () => undefined },
          state: { inboxAssignableAgents: { records: {} } },
          dispatch,
        },
      },
      4865
    );

    expect(dispatch).not.toHaveBeenCalled();
  });
});
