import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const getMock = vi.fn();
const runMock = vi.fn();
const importConversationMock = vi.fn();

const ButtonStub = defineComponent({
  name: 'NextButtonStub',
  props: {
    label: {
      type: String,
      default: '',
    },
    isLoading: {
      type: Boolean,
      default: false,
    },
  },
  emits: ['click'],
  setup(props, { emit }) {
    return () =>
      h(
        'button',
        {
          disabled: props.isLoading,
          onClick: () => emit('click'),
        },
        props.label
      );
  },
});

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/api/captain/evaluations', () => ({
  default: {
    get: getMock,
    run: runMock,
    importConversation: importConversationMock,
  },
}));

vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    name: 'PageLayout',
    setup(_props, { slots }) {
      return () => h('div', slots.body?.());
    },
  }),
}));

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: ButtonStub,
}));

const { default: EvaluationsIndex } = await import('./Index.vue');

const catalogPayload = {
  data: {
    packs: [
      {
        id: 'captain.ai_voice_trace',
        label: 'AI Voice trace integrity',
        description: 'Offline trace checks',
        deterministic: true,
        live_model: false,
        default_enabled: true,
      },
      {
        id: 'captain.conversation_completion',
        label: 'Captain conversation completion',
        description: 'Live checks',
        deterministic: false,
        live_model: true,
        default_enabled: false,
      },
    ],
  },
};

const runPayload = {
  data: {
    result: {
      status: 'pass',
      suite_count: 3,
      total_count: 12,
      passed_count: 12,
      failed_count: 0,
      error_count: 0,
      suites: [
        {
          suite_id: 'captain.ai_voice_trace',
          status: 'pass',
          total_count: 3,
          passed_count: 3,
          failed_count: 0,
          error_count: 0,
        },
      ],
    },
  },
};

describe('Captain evaluations page', () => {
  beforeEach(() => {
    getMock.mockReset();
    runMock.mockReset();
    importConversationMock.mockReset();
    getMock.mockResolvedValue(catalogPayload);
    runMock.mockResolvedValue(runPayload);
    importConversationMock.mockResolvedValue({
      data: { yaml: 'cases:\n  - id: conversation_481_ai_voice_trace\n' },
    });
  });

  it('loads the eval catalog and marks live packs as locked', async () => {
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    expect(getMock).toHaveBeenCalledTimes(1);
    expect(wrapper.text()).toContain('AI Voice trace integrity');
    expect(wrapper.text()).toContain('Captain conversation completion');
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.PACKS.LIVE_LOCKED');
  });

  it('runs deterministic packs and renders the result summary', async () => {
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    const runButton = wrapper
      .findAll('button')
      .find(
        button => button.text() === 'CAPTAIN.EVALUATIONS.RUN_DETERMINISTIC'
      );

    await runButton.trigger('click');
    await flushPromises();

    expect(runMock).toHaveBeenCalledWith({
      pack_ids: ['captain.ai_voice_trace'],
    });
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.RESULT_STATUS.PASS');
    expect(wrapper.text()).toContain('12 / 12');
    expect(wrapper.text()).toContain('captain.ai_voice_trace');
  });

  it('exports a conversation trace fixture preview from the page', async () => {
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    const inputs = wrapper.findAll('input');
    await inputs[0].setValue('57');
    await inputs[1].setValue('481');

    const importButton = wrapper
      .findAll('button')
      .find(button => button.text() === 'CAPTAIN.EVALUATIONS.IMPORT.BUTTON');

    await importButton.trigger('click');
    await flushPromises();

    expect(importConversationMock).toHaveBeenCalledWith({
      inbox_id: '57',
      display_id: '481',
    });
    expect(wrapper.text()).toContain('conversation_481_ai_voice_trace');
  });
});
