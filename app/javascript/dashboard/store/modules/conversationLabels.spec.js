import { afterEach, describe, expect, it, vi } from 'vitest';

import ConversationAPI from '../../api/conversations';
import CommunicationThreadAPI from '../../api/inbox/communicationThread';
import types from '../mutation-types';
import { actions } from './conversationLabels';

describe('conversationLabels actions', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('fetches labels from the communication thread endpoint when the selected chat is a thread', async () => {
    const commit = vi.fn();
    vi.spyOn(CommunicationThreadAPI, 'labels').mockResolvedValue({
      data: { payload: ['vip'] },
    });
    const conversationLabelsSpy = vi
      .spyOn(ConversationAPI, 'getLabels')
      .mockResolvedValue({ data: { payload: [] } });

    await actions.get(
      {
        commit,
        rootGetters: {
          getSelectedChat: { id: 7, is_communication_thread: true },
        },
      },
      7
    );

    expect(CommunicationThreadAPI.labels).toHaveBeenCalledWith(7);
    expect(conversationLabelsSpy).not.toHaveBeenCalled();
    expect(commit).toHaveBeenCalledWith(types.SET_CONVERSATION_LABELS, {
      id: 7,
      data: ['vip'],
    });
  });

  it('updates labels through the communication thread endpoint when explicitly flagged', async () => {
    const commit = vi.fn();
    vi.spyOn(CommunicationThreadAPI, 'updateLabels').mockResolvedValue({
      data: { payload: ['paid'] },
    });
    const conversationUpdateSpy = vi
      .spyOn(ConversationAPI, 'updateLabels')
      .mockResolvedValue({ data: { payload: [] } });

    await actions.update(
      { commit, rootGetters: {} },
      { conversationId: 7, isCommunicationThread: true, labels: ['paid'] }
    );

    expect(CommunicationThreadAPI.updateLabels).toHaveBeenCalledWith(7, [
      'paid',
    ]);
    expect(conversationUpdateSpy).not.toHaveBeenCalled();
    expect(commit).toHaveBeenCalledWith(types.SET_CONVERSATION_LABELS, {
      id: 7,
      data: ['paid'],
    });
  });

  it('updates labels through the communication thread endpoint when the selected chat is a thread and payload omits the explicit flag', async () => {
    const commit = vi.fn();
    vi.spyOn(CommunicationThreadAPI, 'updateLabels').mockResolvedValue({
      data: { payload: ['paid'] },
    });
    const conversationUpdateSpy = vi
      .spyOn(ConversationAPI, 'updateLabels')
      .mockResolvedValue({ data: { payload: [] } });

    await actions.update(
      {
        commit,
        rootGetters: {
          getSelectedChat: { id: 7, is_communication_thread: true },
        },
      },
      { conversationId: 7, labels: ['paid'] }
    );

    expect(CommunicationThreadAPI.updateLabels).toHaveBeenCalledWith(7, [
      'paid',
    ]);
    expect(conversationUpdateSpy).not.toHaveBeenCalled();
  });

  it('sends a change to the communication thread endpoint and stores the labels the server answers with', async () => {
    const commit = vi.fn();
    vi.spyOn(CommunicationThreadAPI, 'changeLabels').mockResolvedValue({
      data: { payload: ['vip', 'card_only', 'paid'] },
    });
    const wholeListSpy = vi
      .spyOn(CommunicationThreadAPI, 'updateLabels')
      .mockResolvedValue({ data: { payload: [] } });

    await actions.update(
      { commit, rootGetters: {} },
      { conversationId: 7, isCommunicationThread: true, add: ['paid'] }
    );

    expect(CommunicationThreadAPI.changeLabels).toHaveBeenCalledWith(7, {
      add: ['paid'],
      remove: undefined,
    });
    expect(wholeListSpy).not.toHaveBeenCalled();
    expect(commit).toHaveBeenCalledWith(types.SET_CONVERSATION_LABELS, {
      id: 7,
      data: ['vip', 'card_only', 'paid'],
    });
  });

  it('sends a change to the conversation endpoint for a plain conversation', async () => {
    const commit = vi.fn();
    vi.spyOn(ConversationAPI, 'changeLabels').mockResolvedValue({
      data: { payload: ['vip'] },
    });

    await actions.update(
      { commit, rootGetters: {} },
      { conversationId: 3, isCommunicationThread: false, remove: ['paid'] }
    );

    expect(ConversationAPI.changeLabels).toHaveBeenCalledWith(3, {
      add: undefined,
      remove: ['paid'],
    });
    expect(commit).toHaveBeenCalledWith(types.SET_CONVERSATION_LABELS, {
      id: 3,
      data: ['vip'],
    });
  });
});
