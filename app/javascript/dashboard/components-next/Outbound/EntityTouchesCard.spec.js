import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import EntityTouchesCard from './EntityTouchesCard.vue';

const mocks = vi.hoisted(() => ({
  accountScopedRoute: vi.fn((name, params, query) => ({ name, params, query })),
  getEnrollments: vi.fn(),
  getTouches: vi.fn(),
  routerPush: vi.fn(),
  useAlert: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, locale: { value: 'en' } }),
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: mocks.routerPush }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ accountScopedRoute: mocks.accountScopedRoute }),
}));

vi.mock('dashboard/api/touches', () => ({
  default: {
    get: mocks.getTouches,
    getEnrollments: mocks.getEnrollments,
  },
}));

vi.mock('dashboard/composables', () => ({ useAlert: mocks.useAlert }));

const ButtonStub = {
  name: 'Button',
  props: ['label'],
  emits: ['click'],
  template: '<button @click="$emit(\'click\')">{{ label }}</button>',
};

const mountComponent = () =>
  mount(EntityTouchesCard, {
    props: {
      conversationId: 101,
      remindableId: 10,
      remindableType: 'CommunicationThread',
    },
    global: {
      mocks: { $t: key => key },
      stubs: {
        Button: ButtonStub,
        Spinner: true,
        TouchEditorDrawer: true,
      },
    },
  });

describe('EntityTouchesCard', () => {
  beforeEach(() => {
    mocks.accountScopedRoute.mockClear();
    mocks.routerPush.mockClear();
    mocks.useAlert.mockClear();
    mocks.getTouches.mockResolvedValue({ data: { payload: [] } });
    mocks.getEnrollments.mockResolvedValue({ data: { payload: [] } });
  });

  it('routes view all with the active conversation and communication thread reminder context', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const viewAllButton = wrapper
      .findAll('button')
      .find(button =>
        button
          .text()
          .includes('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.VIEW_ALL')
      );
    await viewAllButton.trigger('click');

    expect(mocks.accountScopedRoute).toHaveBeenCalledWith(
      'outbound_touches_index',
      {},
      {
        conversation_id: 101,
        remindable_id: 10,
        remindable_type: 'CommunicationThread',
      }
    );
    expect(mocks.routerPush).toHaveBeenCalledWith({
      name: 'outbound_touches_index',
      params: {},
      query: {
        conversation_id: 101,
        remindable_id: 10,
        remindable_type: 'CommunicationThread',
      },
    });
  });

  it('shows a localized message when loading fails, not the raw request error', async () => {
    mocks.getTouches.mockRejectedValue(
      Object.assign(new Error('Request failed with status code 500'), {
        response: { status: 500, data: {} },
      })
    );
    mountComponent();
    await flushPromises();

    expect(mocks.useAlert).toHaveBeenCalledWith(
      'OUTBOUND_WORKSPACE.TOUCHES.ERRORS.LOAD_TOUCHES'
    );
  });

  it('maps a backend reminder error to localized text', async () => {
    mocks.getTouches.mockRejectedValue(
      Object.assign(new Error('Request failed with status code 422'), {
        response: {
          status: 422,
          data: { error: 'An open touch with the same content already exists' },
        },
      })
    );
    mountComponent();
    await flushPromises();

    expect(mocks.useAlert).toHaveBeenCalledWith(
      'OUTBOUND_WORKSPACE.TOUCHES.ERRORS.DUPLICATE'
    );
  });
});
