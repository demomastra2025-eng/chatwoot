import { beforeEach, describe, expect, it, vi } from 'vitest';
import { MESSAGE_TYPE } from 'shared/constants/messages';
import conversationGetters from 'dashboard/store/modules/conversations/getters';

const windowState = vi.hoisted(() => ({ visible: true }));

vi.mock('dashboard/store', () => ({ default: { getters: {} } }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('../faviconHelper', () => ({
  initFaviconSwitcher: vi.fn(),
  showBadgeOnFavicon: vi.fn(),
}));
vi.mock('../WindowVisibilityHelper', () => ({
  default: { isWindowVisible: () => windowState.visible },
}));

import { showBadgeOnFavicon } from '../faviconHelper';
import { DashboardAudioNotificationHelper } from '../DashboardAudioNotificationHelper';

const currentUser = { id: 1, accounts: [{ id: 1, permissions: ['agent'] }] };

const audioInstances = [];
class FakeAudio {
  constructor(url) {
    this.url = url;
    this.load = vi.fn();
    this.play = vi.fn().mockResolvedValue(undefined);
    audioInstances.push(this);
  }
}

// The real getters of the conversations module over a hand made state, so the
// lookups of the helper are checked against the store it runs on.
const storeType = chat =>
  chat.is_communication_thread ? 'communication_thread' : 'conversation';

const buildStore = (chats = [], selected = null) => {
  const state = {
    allConversations: chats,
    selectedChatId: selected ? selected.id : null,
    selectedChatType: selected ? storeType(selected) : null,
  };
  return {
    getters: {
      getCurrentAccountId: 1,
      getSelectedChat: conversationGetters.getSelectedChat(state),
      getConversationById: conversationGetters.getConversationById(state),
      getMineChats: () => [],
    },
  };
};

const buildHelper = (settings = {}, store = buildStore()) => {
  const helper = new DashboardAudioNotificationHelper(store);
  helper.set({ currentUser, ...settings });
  return helper;
};

const message = (overrides = {}) => ({
  id: 1,
  message_type: MESSAGE_TYPE.INCOMING,
  private: false,
  conversation_id: 500,
  sender: { id: 900 },
  conversation: { assignee_id: null },
  ...overrides,
});

const thread = (overrides = {}) => ({
  id: 10,
  is_communication_thread: true,
  status: 'open',
  meta: { assignee: null },
  assignee_id: null,
  channels: [{ conversation_id: 500, status: 'open' }],
  conversation_ids: [500],
  ...overrides,
});

const threadMessage = (overrides = {}) =>
  message({ communication_thread_id: 10, ...overrides });

const playCount = helper => helper.audioConfig.audio.play.mock.calls.length;

describe('DashboardAudioNotificationHelper', () => {
  beforeEach(() => {
    audioInstances.length = 0;
    windowState.visible = false;
    showBadgeOnFavicon.mockClear();
    vi.stubGlobal('Audio', FakeAudio);
  });

  describe('set', () => {
    it('plays bipbop with assigned and unassigned alerts for a user who never chose', () => {
      const helper = buildHelper();

      expect(audioInstances).toHaveLength(1);
      expect(audioInstances[0].url).toBe('/audio/dashboard/bipbop.mp3');
      expect(audioInstances[0].load).toHaveBeenCalledTimes(1);
      expect(helper.notificationConfig).toMatchObject({
        audioAlertType: ['assigned', 'unassigned'],
        playAlertOnlyWhenHidden: true,
      });
      // The 30 s repeat stays off.
      expect(
        helper.notificationConfig.alertIfUnreadConversationExist
      ).toBeFalsy();
      expect(helper.recurringNotificationTimer).toBeNull();
    });

    it('keeps an explicit none off', () => {
      const helper = buildHelper({ audioAlertType: 'none' });

      expect(helper.notificationConfig.audioAlertType).toEqual(['none']);

      helper.onNewMessage(message());

      expect(playCount(helper)).toBe(0);
    });

    it.each(['bell', 'chime', 'magic', 'drumroll', 'unknown', null])(
      'plays bipbop instead of the removed or unknown tone %s',
      tone => {
        const helper = buildHelper({ audioAlertTone: tone });

        expect(helper.audioConfig.tone).toBe('bipbop');
        expect(audioInstances.map(audio => audio.url)).toEqual([
          '/audio/dashboard/bipbop.mp3',
        ]);
      }
    );

    it('loads the file of the chosen tone', () => {
      buildHelper({ audioAlertTone: 'softbell' });

      expect(audioInstances.map(audio => audio.url)).toEqual([
        '/audio/dashboard/softbell.mp3',
      ]);
    });

    it('loads a new file only when the tone changes', () => {
      const helper = buildHelper({ audioAlertTone: 'ping' });

      helper.set({ currentUser, audioAlertTone: 'ping' });
      expect(audioInstances).toHaveLength(1);

      helper.set({ currentUser, audioAlertTone: 'duet' });
      expect(audioInstances.map(audio => audio.url)).toEqual([
        '/audio/dashboard/ping.mp3',
        '/audio/dashboard/duet.mp3',
      ]);
    });
  });

  describe('onNewMessage', () => {
    it('rings for a message of an unassigned conversation', () => {
      const helper = buildHelper();

      helper.onNewMessage(message());

      expect(playCount(helper)).toBe(1);
      expect(showBadgeOnFavicon).toHaveBeenCalledTimes(1);
    });

    it('rings for a message of a conversation assigned to me', () => {
      const helper = buildHelper();

      helper.onNewMessage(message({ conversation: { assignee_id: 1 } }));

      expect(playCount(helper)).toBe(1);
    });

    it('stays silent for a conversation assigned to someone else', () => {
      const helper = buildHelper();

      helper.onNewMessage(message({ conversation: { assignee_id: 2 } }));

      expect(playCount(helper)).toBe(0);
    });

    it('rings for a private note of a teammate', () => {
      const helper = buildHelper();

      helper.onNewMessage(
        message({
          message_type: MESSAGE_TYPE.OUTGOING,
          private: true,
          sender: { id: 2, type: 'user' },
        })
      );

      expect(playCount(helper)).toBe(1);
    });

    it.each([
      ['an automation without a sender', undefined],
      ['an AI agent', { id: 5, type: 'captain_assistant' }],
    ])('stays silent for a private note of %s', (_title, sender) => {
      const helper = buildHelper();

      helper.onNewMessage(
        message({
          message_type: MESSAGE_TYPE.OUTGOING,
          private: true,
          sender,
        })
      );

      expect(playCount(helper)).toBe(0);
    });

    it('stays silent for my own private note', () => {
      const helper = buildHelper();

      helper.onNewMessage(
        message({
          message_type: MESSAGE_TYPE.OUTGOING,
          private: true,
          sender: { id: 1, type: 'user' },
        })
      );

      expect(playCount(helper)).toBe(0);
    });

    it('stays silent for my own message', () => {
      const helper = buildHelper();

      helper.onNewMessage(
        message({ message_type: MESSAGE_TYPE.OUTGOING, sender: { id: 1 } })
      );

      expect(playCount(helper)).toBe(0);
    });

    it('stays silent while the tab is active unless sounds are always on', () => {
      const store = buildStore([{ id: 777, status: 'open' }], { id: 777 });
      const helper = buildHelper({}, store);
      windowState.visible = true;

      helper.onNewMessage(message());
      expect(playCount(helper)).toBe(0);

      helper.set({ currentUser, alwaysPlayAudioAlert: true });
      helper.onNewMessage(message());
      expect(playCount(helper)).toBe(1);
    });

    it('stays silent for a user without access to conversations', () => {
      const helper = buildHelper();
      helper.currentUser = { id: 1, accounts: [{ id: 1, permissions: [] }] };

      helper.onNewMessage(message());

      expect(playCount(helper)).toBe(0);
    });

    it('stays silent for a pending conversation', () => {
      const helper = buildHelper(
        {},
        buildStore([{ id: 500, status: 'pending' }])
      );

      helper.onNewMessage(message());

      expect(playCount(helper)).toBe(0);
    });
  });

  describe('onNewMessage in communication thread mode', () => {
    it('rings for another thread and stays silent for the thread being read', () => {
      const openThread = thread();
      const otherThread = thread({
        id: 11,
        channels: [{ conversation_id: 600, status: 'open' }],
        conversation_ids: [600],
      });
      const helper = buildHelper(
        { alwaysPlayAudioAlert: true },
        buildStore([openThread, otherThread], openThread)
      );
      windowState.visible = true;

      helper.onNewMessage(threadMessage());
      expect(playCount(helper)).toBe(0);

      helper.onNewMessage(
        threadMessage({ conversation_id: 600, communication_thread_id: 11 })
      );
      expect(playCount(helper)).toBe(1);
    });

    it('rings for the open thread when the tab is not active', () => {
      const openThread = thread();
      const helper = buildHelper({}, buildStore([openThread], openThread));

      helper.onNewMessage(threadMessage());

      expect(playCount(helper)).toBe(1);
    });

    it('does not take an unrelated conversation with the id of the open thread for it', () => {
      const openThread = thread({ id: 600 });
      const helper = buildHelper(
        { alwaysPlayAudioAlert: true },
        buildStore([openThread], openThread)
      );
      windowState.visible = true;

      helper.onNewMessage(
        threadMessage({ conversation_id: 600, communication_thread_id: 11 })
      );

      expect(playCount(helper)).toBe(1);
    });

    it('stays silent for a thread handled by the AI agent', () => {
      const pendingThread = thread({
        status: 'pending',
        channels: [{ conversation_id: 500, status: 'pending' }],
      });
      const helper = buildHelper({}, buildStore([pendingThread]));

      helper.onNewMessage(threadMessage());

      expect(playCount(helper)).toBe(0);
    });

    it.each([
      ['no channel yet', []],
      ['a channel without a status', [{ conversation_id: 500 }]],
    ])(
      'stays silent for a new AI agent conversation of a loaded open thread with %s',
      (_title, channels) => {
        // conversation.created stored the pending record; the thread still has the old status.
        const openThread = thread({ channels, conversation_ids: [] });
        const helper = buildHelper(
          {},
          buildStore([openThread, { id: 500, status: 'pending' }])
        );

        helper.onNewMessage(threadMessage());

        expect(playCount(helper)).toBe(0);
      }
    );

    it('rings for a new human conversation of a loaded pending thread', () => {
      const pendingThread = thread({
        status: 'pending',
        channels: [{ conversation_id: 500 }],
      });
      const helper = buildHelper(
        {},
        buildStore([pendingThread, { id: 500, status: 'open' }])
      );

      helper.onNewMessage(threadMessage());

      expect(playCount(helper)).toBe(1);
    });

    it('is not muted by a thread that only shares its id with the conversation', () => {
      const pendingStranger = thread({
        id: 500,
        status: 'pending',
        channels: [],
        conversation_ids: [],
      });
      const helper = buildHelper({}, buildStore([pendingStranger]));

      helper.onNewMessage(threadMessage());

      expect(playCount(helper)).toBe(1);
    });

    it('follows the assignee of the thread, not of the channel conversation', () => {
      const mineThread = thread({ meta: { assignee: { id: 1 } } });
      const colleagueThread = thread({
        id: 12,
        meta: { assignee: { id: 2 } },
        channels: [{ conversation_id: 700, status: 'open' }],
        conversation_ids: [700],
      });
      const helper = buildHelper(
        { audioAlertType: 'assigned' },
        buildStore([mineThread, colleagueThread])
      );

      helper.onNewMessage(threadMessage());
      expect(playCount(helper)).toBe(1);

      helper.onNewMessage(
        threadMessage({
          conversation_id: 700,
          communication_thread_id: 12,
          conversation: { assignee_id: 1 },
        })
      );
      expect(playCount(helper)).toBe(1);
    });

    it('stays silent for a thread of a colleague whose channel conversation is unassigned', () => {
      const colleagueThread = thread({ meta: { assignee: { id: 2 } } });
      const helper = buildHelper({}, buildStore([colleagueThread]));

      helper.onNewMessage(threadMessage());

      expect(playCount(helper)).toBe(0);
    });

    it('uses the conversation assignee while the thread is not loaded', () => {
      const helper = buildHelper({ audioAlertType: 'assigned' });

      helper.onNewMessage(threadMessage({ conversation: { assignee_id: 1 } }));

      expect(playCount(helper)).toBe(1);
    });
  });
});
