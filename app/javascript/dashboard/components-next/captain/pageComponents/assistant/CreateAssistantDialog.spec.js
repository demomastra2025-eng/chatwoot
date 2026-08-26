import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { h } from 'vue';

import CreateAssistantDialog from './CreateAssistantDialog.vue';

const dispatchMock = vi.fn();
const useStoreMock = vi.fn();
const useAlertMock = vi.fn();

vi.mock('dashboard/composables/store', () => ({
  useStore: (...args) => useStoreMock(...args),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => useAlertMock(...args),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

const dialogStub = {
  name: 'Dialog',
  props: [
    'title',
    'description',
    'showCancelButton',
    'showConfirmButton',
    'confirmButtonLabel',
    'disableConfirmButton',
    'isLoading',
    'width',
  ],
  emits: ['close', 'confirm'],
  setup(_, { slots, expose }) {
    expose({
      close: vi.fn(),
      open: vi.fn(),
    });

    return () => h('div', [slots.default?.(), slots.footer?.()]);
  },
};

const inputStub = {
  name: 'Input',
  props: ['modelValue', 'message', 'messageType', 'label', 'placeholder'],
  emits: ['update:modelValue'],
  template:
    '<input @input="$emit(\'update:modelValue\', $event.target.value)" />',
};

describe('CreateAssistantDialog', () => {
  beforeEach(() => {
    dispatchMock.mockReset();
    useAlertMock.mockReset();
    useStoreMock.mockReturnValue({
      dispatch: dispatchMock,
    });
  });

  it('renders the compact create flow instead of the full assistant form', () => {
    const wrapper = shallowMount(CreateAssistantDialog, {
      props: {
        type: 'create',
      },
      global: {
        stubs: {
          Dialog: dialogStub,
          Input: inputStub,
          AssistantForm: true,
        },
      },
    });

    expect(wrapper.findComponent({ name: 'Input' }).exists()).toBe(true);
    expect(wrapper.findComponent({ name: 'AssistantForm' }).exists()).toBe(
      false
    );
  });

  it('uses the wider create dialog width for agent and assistant creation', () => {
    const wrapper = shallowMount(CreateAssistantDialog, {
      props: {
        type: 'create',
      },
      global: {
        stubs: {
          Dialog: dialogStub,
          Input: inputStub,
          AssistantForm: true,
        },
      },
    });

    expect(wrapper.findComponent({ name: 'Dialog' }).props('width')).toBe(
      'lg-plus'
    );
  });

  it('creates an AI Agent from its name with default settings', async () => {
    dispatchMock.mockResolvedValueOnce({ id: 77, name: 'Sales Agent' });

    const wrapper = shallowMount(CreateAssistantDialog, {
      props: {
        type: 'create',
      },
      global: {
        stubs: {
          Dialog: dialogStub,
          Input: inputStub,
          AssistantForm: true,
        },
      },
    });

    await wrapper.findComponent({ name: 'Input' }).setValue('Sales Agent');
    wrapper.findComponent({ name: 'Dialog' }).vm.$emit('confirm');

    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/create', {
      name: 'Sales Agent',
      description:
        'CAPTAIN.ASSISTANTS.CREATE.DEFAULT_INSTRUCTION.EXTERNAL_AGENT',
      config: {
        feature_faq: false,
        feature_memory: false,
        feature_citation: false,
        context_access: {},
        tool_access: {
          agent: {
            enabled: true,
            tool_ids: ['faq_lookup', 'handoff'],
          },
        },
      },
    });
    expect(wrapper.emitted('created')?.[0]?.[0]).toMatchObject({
      id: 77,
      name: 'Sales Agent',
    });
  });
});
