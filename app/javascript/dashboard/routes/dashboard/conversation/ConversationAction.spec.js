import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import ConversationAction from './ConversationAction.vue';

vi.mock('dashboard/composables/useAgentsList', () => ({
  useAgentsList: () => ({ agentsList: [] }),
}));
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: () => vi.fn(),
}));

describe('ConversationAction priority', () => {
  it('renders all 4 priority options and supports selecting or toggling off priority', async () => {
    const dispatch = vi.fn().mockResolvedValue(null);
    const chat = {
      id: 12,
      priority: 'low',
      meta: { assignee: null, team: null },
    };
    const wrapper = mount(ConversationAction, {
      props: { conversationId: 12 },
      global: {
        mocks: {
          $t: key => key,
          $store: {
            getters: {
              getSelectedChat: chat,
              getCurrentUser: { id: 2 },
              'teams/getTeams': [],
            },
            dispatch,
          },
        },
        stubs: {
          ContactDetailsItem: true,
          MultiselectDropdown: true,
          NextButton: true,
        },
      },
    });

    const buttons = wrapper.findAll('[role="group"] button');
    expect(buttons).toHaveLength(4);
    expect(buttons.map(button => button.text())).toEqual([
      'CONTACT_PANEL.PRIORITY_LOW',
      'CONTACT_PANEL.PRIORITY_MEDIUM',
      'CONTACT_PANEL.PRIORITY_HIGH',
      'CONTACT_PANEL.PRIORITY_URGENT',
    ]);
    expect(
      wrapper.find('[role="group"] button[aria-pressed="true"]').text()
    ).toBe('CONTACT_PANEL.PRIORITY_LOW');
    expect(
      wrapper
        .findAll('contact-details-item-stub')
        .map(item => item.attributes('title'))
    ).toEqual(['CONTACT_PANEL.ASSIGNEE_LABEL', 'CONTACT_PANEL.PRIORITY_LABEL']);

    await buttons[3].trigger('click');
    expect(dispatch).toHaveBeenCalledWith('setCurrentChatPriority', {
      priority: 'urgent',
      conversationId: 12,
    });
    expect(dispatch).toHaveBeenCalledWith('assignPriority', {
      priority: 'urgent',
      conversationId: 12,
    });

    await buttons[0].trigger('click');
    expect(dispatch).toHaveBeenCalledWith('setCurrentChatPriority', {
      priority: null,
      conversationId: 12,
    });
    expect(dispatch).toHaveBeenCalledWith('assignPriority', {
      priority: null,
      conversationId: 12,
    });
  });
});
