import { mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { describe, expect, it, vi } from 'vitest';

import ConversationContextMenu from './Index.vue';

vi.mock('dashboard/composables/useAdmin', () => ({
  useAdmin: () => ({ isAdmin: false }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('shared/helpers/clipboard', () => ({
  copyTextToClipboard: vi.fn(),
}));

const labels = [
  {
    id: 10,
    title: 'vip',
    color: '#f97316',
    marker_type: 'color',
  },
];

const createTestStore = () =>
  createStore({
    getters: {
      getCurrentUser: () => ({ id: 1, name: 'Agent' }),
      getCurrentAccountId: () => 1,
    },
    modules: {
      labels: {
        namespaced: true,
        getters: {
          getLabels: () => labels,
        },
      },
      teams: {
        namespaced: true,
        getters: {
          getTeams: () => [],
        },
      },
      inboxAssignableAgents: {
        namespaced: true,
        getters: {
          getUIFlags: () => ({ isFetching: false }),
        },
        actions: {
          fetch: vi.fn(),
        },
      },
    },
  });

const mountComponent = props =>
  mount(ConversationContextMenu, {
    props: {
      chatId: 630,
      status: 'open',
      inboxId: 4593,
      conversationLabels: [],
      allowedOptions: ['label'],
      ...props,
    },
    global: {
      plugins: [createTestStore()],
      mocks: {
        $t: key => key,
      },
      stubs: {
        AgentLoadingPlaceholder: true,
        Avatar: true,
        FluentIcon: true,
        Icon: true,
        'fluent-icon': true,
      },
    },
  });

describe('ConversationContextMenu', () => {
  it('offers add task for an allowed dialog and emits the action', async () => {
    const wrapper = mountComponent({
      allowedOptions: ['add-task'],
      canAddTask: true,
    });
    const action = wrapper
      .findAllComponents({ name: 'MenuItem' })
      .find(item => item.props('option')?.key === 'add-task');
    expect(action.exists()).toBe(true);
    await action.trigger('click');
    expect(wrapper.emitted('addTask')).toEqual([[]]);
  });

  it('does not request agents for an inbox that no longer exists', () => {
    const dispatch = vi.fn();
    ConversationContextMenu.mounted.call({
      inboxId: 4865,
      $store: {
        getters: { 'inboxes/getInbox': () => undefined },
        dispatch,
      },
    });

    expect(dispatch).not.toHaveBeenCalled();
  });

  it('emits label assignment from desktop submenu clicks', async () => {
    const wrapper = mountComponent();

    await wrapper.find('.submenu .menu').trigger('click');

    expect(wrapper.emitted('assignLabel')).toEqual([[labels[0]]]);
  });

  it('emits label assignment from mobile submenu taps', async () => {
    const wrapper = mountComponent({ mobile: true });

    await wrapper.find('.menu-with-submenu').trigger('click');
    await wrapper.find('.mobile-submenu .menu').trigger('click');

    expect(wrapper.emitted('assignLabel')).toEqual([[labels[0]]]);
  });
});
