import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { nextTick } from 'vue';

const mocks = vi.hoisted(() => ({
  assistants: [{ id: 2 }],
  dispatch: vi.fn(),
  replace: vi.fn(),
  route: {
    params: {
      accountId: '1',
      navigationPath: 'captain_assistants_playground_index',
    },
  },
  uiSettings: {
    value: {
      last_active_assistant_id: 2,
    },
  },
}));

vi.mock('vuex', () => ({
  useStore: () => ({
    dispatch: mocks.dispatch,
    getters: {
      'captainAssistants/getRecords': mocks.assistants,
    },
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => mocks.route,
  useRouter: () => ({
    replace: mocks.replace,
  }),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: mocks.uiSettings,
  }),
}));

vi.mock('dashboard/components-next/spinner/Spinner.vue', () => ({
  default: {
    name: 'Spinner',
    template: '<div />',
  },
}));

const { default: AssistantsIndexPage } = await import(
  './AssistantsIndexPage.vue'
);

const mountPage = async () => {
  const wrapper = mount(AssistantsIndexPage);
  await flushPromises();
  await nextTick();
  return wrapper;
};

describe('AssistantsIndexPage', () => {
  beforeEach(() => {
    mocks.dispatch.mockReset();
    mocks.dispatch.mockResolvedValue({});
    mocks.replace.mockReset();
    mocks.assistants = [{ id: 2 }];
    mocks.uiSettings.value = { last_active_assistant_id: 2 };
    mocks.route.params = {
      accountId: '1',
      navigationPath: 'captain_assistants_playground_index',
    };
  });

  it('routes the legacy playground sidebar target to prompts', async () => {
    await mountPage();

    expect(mocks.replace).toHaveBeenCalledWith({
      name: 'captain_assistants_prompts_index',
      params: {
        accountId: '1',
        assistantId: 2,
      },
      replace: true,
    });
  });

  it('routes the removed channels target to channel settings list', async () => {
    mocks.route.params = {
      accountId: '1',
      navigationPath: 'captain_assistants_channels_index',
    };

    await mountPage();

    expect(mocks.replace).toHaveBeenCalledWith({
      name: 'settings_inbox_list',
      params: {
        accountId: '1',
      },
      replace: true,
    });
  });
});
