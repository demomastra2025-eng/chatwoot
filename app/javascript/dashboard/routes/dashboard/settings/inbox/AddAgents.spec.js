import { flushPromises, shallowMount } from '@vue/test-utils';

import AddAgents from './AddAgents.vue';

const inboxMembersUpdateMock = vi.hoisted(() => vi.fn());
const routerReplaceMock = vi.hoisted(() => vi.fn());

vi.mock('../../../../api/inboxMembers', () => ({
  default: {
    update: inboxMembersUpdateMock,
  },
}));

vi.mock('../../../index', () => ({
  default: {
    replace: routerReplaceMock,
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

const buildWrapper = () =>
  shallowMount(AddAgents, {
    global: {
      mocks: {
        $t: key => key,
        $route: {
          name: 'settings_inboxes_add_agents',
          params: { accountId: '530', inbox_id: '4690' },
          query: {},
        },
        $store: {
          dispatch: vi.fn(),
          getters: {
            'agents/getAgents': [],
          },
        },
      },
      stubs: {
        PageHeader: {
          template: '<section><slot name="content" /><slot /></section>',
        },
        NextButton: {
          template: '<button type="submit"><slot /></button>',
        },
        TagInput: true,
      },
    },
  });

describe('AddAgents', () => {
  beforeEach(() => {
    inboxMembersUpdateMock.mockReset();
    routerReplaceMock.mockReset();
    inboxMembersUpdateMock.mockResolvedValue({});
  });

  it('preserves accountId when moving to the finish step', async () => {
    const wrapper = buildWrapper();
    wrapper.vm.selectedAgentIds = [7, 8];

    await wrapper.vm.addAgents();
    await flushPromises();

    expect(inboxMembersUpdateMock).toHaveBeenCalledWith({
      inboxId: '4690',
      agentList: [7, 8],
    });
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inbox_finish',
      params: {
        accountId: '530',
        inbox_id: '4690',
      },
      query: {},
    });
  });
});
