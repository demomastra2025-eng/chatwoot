import { describe, expect, it, vi, beforeEach } from 'vitest';

import ConversationView from './ConversationView.vue';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';

vi.mock('shared/helpers/mitt', () => ({
  emitter: {
    emit: vi.fn(),
  },
}));

describe('ConversationView', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('#setActiveChat', () => {
    it('re-emits scroll intent when opening the already active conversation route', () => {
      const selectedConversation = { id: 42 };
      const context = {
        conversationId: 42,
        communicationThreadMode: false,
        currentChat: { id: 42 },
        findConversation: vi.fn(() => selectedConversation),
        $route: { query: {} },
        $store: { dispatch: vi.fn() },
      };

      ConversationView.methods.setActiveChat.call(context);

      expect(context.$store.dispatch).not.toHaveBeenCalled();
      expect(emitter.emit).toHaveBeenCalledWith(BUS_EVENTS.SCROLL_TO_MESSAGE, {
        messageId: undefined,
      });
    });
  });
});
