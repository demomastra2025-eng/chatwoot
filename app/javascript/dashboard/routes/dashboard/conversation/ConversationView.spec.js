import { describe, expect, it, vi, beforeEach } from 'vitest';

import ConversationView from './ConversationView.vue';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';

vi.mock('shared/helpers/mitt', () => ({
  emitter: {
    emit: vi.fn(),
    // The webphone client in the import chain subscribes on load.
    on: vi.fn(),
    off: vi.fn(),
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

  describe('panes on a phone', () => {
    const paneContext = (displayType, conversationId) => {
      const context = {
        conversationId,
        uiSettings: { conversation_display_type: displayType },
      };
      context.isOnExpandedLayout =
        ConversationView.computed.isOnExpandedLayout.call(context);
      return context;
    };

    it('shows only the open dialog under the expanded layout', () => {
      const context = paneContext('expanded', 13890);

      expect(context.isOnExpandedLayout).toBe(true);
      expect(ConversationView.computed.showConversationList.call(context)).toBe(
        false
      );
      expect(ConversationView.computed.showMessageView.call(context)).toBe(
        true
      );
    });

    it('shows only the list under the expanded layout when no dialog is open', () => {
      const context = paneContext('expanded', 0);

      expect(ConversationView.computed.showConversationList.call(context)).toBe(
        true
      );
      expect(ConversationView.computed.showMessageView.call(context)).toBe(
        false
      );
    });

    it('shows the list and the dialog side by side under the condensed layout', () => {
      // The desktop layout: a phone must never be left in it.
      const context = paneContext('condensed', 13890);

      expect(ConversationView.computed.showConversationList.call(context)).toBe(
        true
      );
      expect(ConversationView.computed.showMessageView.call(context)).toBe(
        true
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

  describe('#mounted', () => {
    it('does not fetch portals on mount and skips agents/get when agents are already loaded', () => {
      const context = {
        initialize: vi.fn(),
        setActiveChat: vi.fn(),
        $watch: vi.fn(),
        $store: {
          getters: {
            'agents/getAgents': [{ id: 1, name: 'Agent' }],
            'agents/getUIFlags': { isFetching: false },
          },
          dispatch: vi.fn(),
        },
      };

      ConversationView.mounted.call(context);

      expect(context.$store.dispatch).not.toHaveBeenCalledWith('agents/get');
      expect(context.$store.dispatch).not.toHaveBeenCalledWith('portals/index');
      expect(context.initialize).toHaveBeenCalledTimes(1);
    });

    it('dispatches agents/get on mount only when agents store is empty and not fetching', () => {
      const context = {
        initialize: vi.fn(),
        setActiveChat: vi.fn(),
        $watch: vi.fn(),
        $store: {
          getters: {
            'agents/getAgents': [],
            'agents/getUIFlags': { isFetching: false },
          },
          dispatch: vi.fn(),
        },
      };

      ConversationView.mounted.call(context);

      expect(context.$store.dispatch).toHaveBeenCalledWith('agents/get');
      expect(context.$store.dispatch).not.toHaveBeenCalledWith('portals/index');
    });
  });
});
