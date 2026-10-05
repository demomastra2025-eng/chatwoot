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

  const mountCreate = () =>
    shallowMount(CreateAssistantDialog, {
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

  it('renders the compact create flow instead of the full assistant form', () => {
    const wrapper = mountCreate();

    expect(wrapper.findComponent({ name: 'Input' }).exists()).toBe(true);
    expect(wrapper.findComponent({ name: 'AssistantForm' }).exists()).toBe(
      false
    );
  });

  it('asks only for the name: there is no choice between an agent and an assistant', () => {
    const wrapper = mountCreate();

    expect(wrapper.findAllComponents({ name: 'Input' })).toHaveLength(1);
    expect(wrapper.findAll('button')).toHaveLength(0);
    expect(wrapper.html()).not.toContain('USAGE_MODE');
  });

  it('uses the wider create dialog width', () => {
    const wrapper = mountCreate();

    expect(wrapper.findComponent({ name: 'Dialog' }).props('width')).toBe(
      'lg-plus'
    );
  });

  it('creates an AI agent from its name with default settings', async () => {
    dispatchMock.mockResolvedValueOnce({ id: 77, name: 'Sales Agent' });

    const wrapper = mountCreate();

    await wrapper.findComponent({ name: 'Input' }).setValue('Sales Agent');
    wrapper.findComponent({ name: 'Dialog' }).vm.$emit('confirm');

    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/create', {
      name: 'Sales Agent',
      usage_mode: 'external_agent',
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

  it('does not create an assistant without a name', async () => {
    const wrapper = mountCreate();

    wrapper.findComponent({ name: 'Dialog' }).vm.$emit('confirm');
    await flushPromises();

    expect(dispatchMock).not.toHaveBeenCalled();
  });

  it('saves edits of an existing assistant without touching its kind', async () => {
    dispatchMock.mockResolvedValue({ id: 8, name: 'Team helper' });

    const wrapper = shallowMount(CreateAssistantDialog, {
      props: {
        type: 'edit',
        selectedAssistant: { id: 8, usage_mode: 'internal_assistant' },
      },
      global: {
        stubs: {
          Dialog: dialogStub,
          Input: inputStub,
          AssistantForm: true,
        },
      },
    });

    wrapper.findComponent({ name: 'AssistantForm' }).vm.$emit('submit', {
      assistant: { name: 'Team helper', config: {} },
      avatar: null,
      removeAvatar: false,
    });
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/update', {
      id: 8,
      name: 'Team helper',
      config: {},
    });
  });
});
