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
      is_touch_sidebar_open: false,
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

    it('keeps the existing touch panel behaviour', () => {
      const context = {
        currentChat: { id: 42 },
        activePanel: null,
        uiSettings: { ...closedPanels, is_touch_sidebar_open: true },
      };

      expect(ConversationView.computed.shouldShowSidebar.call(context)).toBe(
        true
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
});
