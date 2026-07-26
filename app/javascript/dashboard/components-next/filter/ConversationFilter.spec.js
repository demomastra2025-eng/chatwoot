import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import ConversationFilter from './ConversationFilter.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useTrack: vi.fn(),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: vi.fn() }),
}));

vi.mock('./provider.js', () => ({
  useConversationFilterContext: () => ({ filterTypes: [] }),
}));

vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => ({
    pipelines: [],
    ui: { isLoadingPipelines: false },
    loadPipelines: vi.fn().mockResolvedValue(),
  }),
}));

const mountComponent = modelValue =>
  mount(ConversationFilter, {
    props: { modelValue },
    global: {
      mocks: { $t: key => key },
      stubs: {
        Button: {
          template: '<button><slot /></button>',
        },
        ConditionRow: {
          emits: ['remove'],
          template:
            '<button data-testid="remove-condition" @click="$emit(\'remove\')">remove</button>',
        },
        Input: true,
      },
    },
  });

describe('ConversationFilter', () => {
  it('resets the status filter to the default open status', async () => {
    const wrapper = mountComponent([
      {
        attributeKey: 'status',
        filterOperator: 'equal_to',
        values: [{ id: 'resolved', name: 'Resolved' }],
        queryOperator: 'and',
      },
    ]);

    const clearButton = wrapper
      .findAll('button')
      .find(button => button.text() === 'FILTER.CLEAR_BUTTON_LABEL');
    await clearButton.trigger('click');

    expect(wrapper.emitted('update:modelValue').at(-1)[0]).toEqual([
      {
        attributeKey: 'status',
        filterOperator: 'equal_to',
        values: [
          {
            id: 'open',
            name: 'CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.open.TEXT',
          },
        ],
        queryOperator: 'and',
      },
    ]);
  });

  it('restores the default open status when the only condition is removed', async () => {
    const wrapper = mountComponent([
      {
        attributeKey: 'status',
        filterOperator: 'equal_to',
        values: [{ id: 'pending', name: 'Pending' }],
        queryOperator: 'and',
      },
    ]);

    await wrapper.find('[data-testid="remove-condition"]').trigger('click');

    expect(wrapper.emitted('update:modelValue').at(-1)[0][0]).toMatchObject({
      attributeKey: 'status',
      filterOperator: 'equal_to',
      values: [{ id: 'open' }],
      queryOperator: 'and',
    });
  });
});
