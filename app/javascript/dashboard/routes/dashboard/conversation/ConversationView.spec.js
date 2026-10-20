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

  describe('#shouldShowSidebar', () => {
    const closedPanels = {
      is_contact_sidebar_open: false,
      is_crm_deal_panel_open: false,
      is_scheduling_appointments_panel_open: false,
    };

    it.each(['contact', 'deals', 'appointments'])(
      'opens the route sidebar for an available %s panel',
      activePanel => {
        const context = {
          currentChat: { id: 42 },
          activePanel,
          uiSettings: closedPanels,
        };

        expect(ConversationView.computed.shouldShowSidebar.call(context)).toBe(
          true
        );
      }
    );

    it('keeps the route sidebar closed for an unavailable persisted panel', () => {
      const context = {
        currentChat: { id: 42 },
        activePanel: null,
        uiSettings: { ...closedPanels, is_crm_deal_panel_open: true },
      };

      expect(ConversationView.computed.shouldShowSidebar.call(context)).toBe(
        false
      );
    });

    it('ignores a persisted reminders panel flag', () => {
      const context = {
        currentChat: { id: 42 },
        activePanel: null,
        uiSettings: { ...closedPanels, is_touch_sidebar_open: true },
      };

      expect(ConversationView.computed.shouldShowSidebar.call(context)).toBe(
        false
      );
    });

    it('never opens the sidebar without a selected chat', () => {
      const context = {
        currentChat: {},
        activePanel: 'contact',
        uiSettings: closedPanels,
      };

      expect(ConversationView.computed.shouldShowSidebar.call(context)).toBe(
        false
      );
    });
  });

  describe('route leave lifecycle', () => {
    it('marks route leave in-flight without blanking out selected chat before unmount', () => {
      const next = vi.fn();
      const context = {
        conversationId: 3889,
        isLeavingConversationRoute: false,
        $store: { dispatch: vi.fn() },
      };

      ConversationView.beforeRouteLeave.call(context, {}, {}, next);

      expect(context.isLeavingConversationRoute).toBe(true);
      expect(context.$store.dispatch).not.toHaveBeenCalledWith(
        'clearSelectedState'
      );
      expect(next).toHaveBeenCalledWith();
    });

    it('clears selected chat state when ConversationView unmounts', () => {
      const context = {
        conversationId: 3889,
        currentChat: { id: 3889 },
        isLeavingConversationRoute: false,
        $store: { dispatch: vi.fn() },
      };

      ConversationView.beforeUnmount.call(context);

      expect(context.isLeavingConversationRoute).toBe(true);
      expect(context.$store.dispatch).toHaveBeenCalledWith(
        'clearSelectedState'
      );
    });

    it('does not replace the route while leaving ConversationView', () => {
      const context = {
        isLeavingConversationRoute: true,
        communicationThreadMode: false,
        conversationId: 3889,
        currentChat: { id: 3889, inbox_id: 7 },
        $route: { name: 'inbox_conversation', params: {}, query: {}, hash: '' },
        $router: { replace: vi.fn() },
      };

      ConversationView.methods.normalizeConversationRoute.call(context);

      expect(context.$router.replace).not.toHaveBeenCalled();
    });
  });
});
