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
  it('shows an existing low priority and updates urgency through the same store action', async () => {
    const dispatch = vi.fn().mockResolvedValue(null);
    const wrapper = mount(ConversationAction, {
      props: { conversationId: 12 },
      global: {
        mocks: {
          $t: key => key,
          $store: {
            getters: {
              getSelectedChat: {
                id: 12,
                priority: 'low',
                meta: { assignee: null, team: null },
              },
              getCurrentUser: { id: 2 },
              'teams/getTeams': [],
            },
            dispatch,
          },
        },
        stubs: {
          ContactDetailsItem: true,
          MultiselectDropdown: true,
          ConversationLabels: true,
          NextButton: true,
        },
      },
    });

    expect(wrapper.findAll('[role="group"] button')).toHaveLength(4);
    expect(
      wrapper.find('[role="group"] button[aria-pressed="true"]').text()
    ).toBe('CONVERSATION.PRIORITY.OPTIONS.LOW');
    await wrapper.findAll('[role="group"] button')[1].trigger('click');
    expect(dispatch).toHaveBeenCalledWith('setCurrentChatPriority', {
      priority: 'urgent',
      conversationId: 12,
    });
    expect(dispatch).toHaveBeenCalledWith('assignPriority', {
      priority: 'urgent',
      conversationId: 12,
    });
  });
});
