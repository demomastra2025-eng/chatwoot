/* eslint-disable vue/one-component-per-file */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const getMock = vi.fn();
const runMock = vi.fn();
const getRunMock = vi.fn();
const importConversationMock = vi.fn();
const runDatasetMock = vi.fn();
const generateRedTeamMock = vi.fn();

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
    disabled: {
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
          disabled: props.isLoading || props.disabled,
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
    getRun: getRunMock,
    importConversation: importConversationMock,
    runDataset: runDatasetMock,
    generateRedTeam: generateRedTeamMock,
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
        description: 'Trace checks',
        deterministic: true,
        live_model: false,
        default_enabled: true,
      },
      {
        id: 'captain.event_contract_trace',
        label: 'Captain event-contract trace fixtures',
        description: 'Event contract checks',
        deterministic: true,
        live_model: false,
        default_enabled: true,
      },
      {
        id: 'captain.conversation_completion',
        label: 'Captain conversation completion',
        description: 'LLM checks',
        deterministic: false,
        live_model: true,
        default_enabled: false,
      },
    ],
    eval_runs: {
      llm_model_enabled: true,
      max_budget_cents: 500,
      default_budget_cents: 100,
      max_cases: 10,
      default_max_cases: 3,
    },
    tribunal: {
      available_assertions: ['contains', 'not_contains', 'similar'],
      judge_names: ['faithful', 'onelink_brand_voice'],
      report_formats: ['json', 'html', 'junit', 'github'],
      red_team_categories: ['encoding', 'injection', 'jailbreak'],
      max_concurrency: 8,
    },
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

const findButton = (wrapper, label) =>
  wrapper.findAll('button').find(button => button.text() === label);

describe('Captain evaluations page', () => {
  beforeEach(() => {
    getMock.mockReset();
    runMock.mockReset();
    getRunMock.mockReset();
    importConversationMock.mockReset();
    runDatasetMock.mockReset();
    generateRedTeamMock.mockReset();
    getMock.mockResolvedValue(catalogPayload);
    runMock.mockResolvedValue(runPayload);
    getRunMock.mockResolvedValue({
      data: {
        run: {
          id: 123,
          status: 'passed',
          result_summary: {
            suite_count: 1,
            passed_count: 1,
            failed_count: 0,
            suite_ids: ['captain.conversation_completion'],
          },
        },
      },
    });
    importConversationMock.mockResolvedValue({
      data: { yaml: 'cases:\n  - id: conversation_481_ai_voice_trace\n' },
    });
    runDatasetMock.mockResolvedValue({
      data: { report: '{"summary":{"total":1,"passed":1}}' },
    });
    generateRedTeamMock.mockResolvedValue({
      data: { attacks: [{ type: 'base64', prompt: 'encoded attack' }] },
    });
  });

  it('loads the eval catalog as one selectable pack list', async () => {
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    expect(getMock).toHaveBeenCalledTimes(1);
    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.PACK_COPY.AI_VOICE.LABEL'
    );
    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.PACK_COPY.COMPLETION.LABEL'
    );
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.PACKS.DETERMINISTIC');
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.PACKS.LLM_MODEL');
    expect(wrapper.text()).not.toContain(
      'CAPTAIN.EVALUATIONS.PACKS.LIVE_LOCKED'
    );
  });

  it('runs the default selected eval packs and renders the result summary', async () => {
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.RUN_EVALS').trigger('click');
    await flushPromises();

    expect(runMock).toHaveBeenCalledWith({
      pack_ids: ['captain.ai_voice_trace', 'captain.event_contract_trace'],
      acknowledge_llm_cost: false,
      budget_cents: 100,
      max_cases: 3,
    });
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.RESULT_STATUS.PASS');
    expect(wrapper.text()).toContain('12 / 12');
    expect(wrapper.text()).toContain('captain.ai_voice_trace');
  });

  it('queues LLM-backed eval packs from the same run button with explicit budget and acknowledgement', async () => {
    runMock.mockResolvedValueOnce({
      data: {
        run: {
          id: 123,
          status: 'queued',
          mode: 'evals',
          pack_ids: [
            'captain.ai_voice_trace',
            'captain.event_contract_trace',
            'captain.conversation_completion',
          ],
        },
        eval_runs: catalogPayload.data.eval_runs,
      },
    });
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    await wrapper
      .findAll('[data-testid="eval-pack-checkbox"]')[2]
      .setValue(true);
    await wrapper.find('[data-testid="eval-budget-cents"]').setValue('75');
    await wrapper.find('[data-testid="eval-max-cases"]').setValue('2');
    await wrapper.find('[data-testid="eval-acknowledge-cost"]').setValue(true);

    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.RUN_EVALS').trigger('click');
    await flushPromises();

    expect(runMock).toHaveBeenCalledWith({
      pack_ids: [
        'captain.ai_voice_trace',
        'captain.event_contract_trace',
        'captain.conversation_completion',
      ],
      acknowledge_llm_cost: true,
      budget_cents: 75,
      max_cases: 2,
    });
    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.RUN.LAST_RUN_WITH_ID'
    );
  });

  it('refreshes queued eval run status from the page', async () => {
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    runMock.mockResolvedValueOnce({
      data: { run: { id: 123, status: 'queued' } },
    });
    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.RUN_EVALS').trigger('click');
    await flushPromises();

    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.RUN.REFRESH').trigger(
      'click'
    );
    await flushPromises();

    expect(getRunMock).toHaveBeenCalledWith(123);
    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.RUN.STATUS_WITH_VALUE'
    );
    expect(wrapper.text()).toContain('captain.conversation_completion');
  });

  it('does not render raw eval run result payloads from status responses', async () => {
    getRunMock.mockResolvedValueOnce({
      data: {
        run: {
          id: 123,
          status: 'passed',
          result: { cases: [{ input: 'secret customer prompt' }] },
          result_summary: {
            suite_count: 1,
            passed_count: 1,
            failed_count: 0,
            suite_ids: ['captain.ai_voice_trace'],
          },
        },
      },
    });
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    runMock.mockResolvedValueOnce({
      data: { run: { id: 123, status: 'queued' } },
    });
    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.RUN_EVALS').trigger('click');
    await flushPromises();
    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.RUN.REFRESH').trigger(
      'click'
    );
    await flushPromises();

    expect(wrapper.find('[data-testid="eval-run-summary"]').exists()).toBe(
      true
    );
    expect(wrapper.text()).toContain('captain.ai_voice_trace');
    expect(wrapper.text()).not.toContain('secret customer prompt');
  });

  it('shows backend validation errors for eval runs', async () => {
    runMock.mockRejectedValueOnce({
      response: { data: { error: 'llm_model_eval_already_running' } },
    });
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.RUN_EVALS').trigger('click');
    await flushPromises();

    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.ERRORS.RUN_FAILED: llm_model_eval_already_running'
    );
  });

  it('exports a conversation trace fixture preview from the page', async () => {
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    await wrapper.find('[data-testid="import-inbox-id"]').setValue('57');
    await wrapper.find('[data-testid="import-display-id"]').setValue('481');

    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.IMPORT.BUTTON').trigger(
      'click'
    );
    await flushPromises();

    expect(importConversationMock).toHaveBeenCalledWith({
      inbox_id: '57',
      display_id: '481',
    });
    expect(wrapper.text()).toContain('conversation_481_ai_voice_trace');
  });

  it('runs generic Tribunal datasets with a selected report format', async () => {
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    await wrapper
      .find('[data-testid="tribunal-dataset-files"]')
      .setValue('config/llm_evals/datasets/captain_sample.yml');
    await wrapper
      .find('[data-testid="tribunal-dataset-format"]')
      .setValue('json');
    await wrapper
      .find('[data-testid="tribunal-dataset-concurrency"]')
      .setValue('2');
    await wrapper
      .find('[data-testid="tribunal-dataset-threshold"]')
      .setValue('0.9');

    await findButton(
      wrapper,
      'CAPTAIN.EVALUATIONS.TRIBUNAL.DATASET_BUTTON'
    ).trigger('click');
    await flushPromises();

    expect(runDatasetMock).toHaveBeenCalledWith({
      files: ['config/llm_evals/datasets/captain_sample.yml'],
      format: 'json',
      strict: true,
      allow_live_assertions: false,
      acknowledge_llm_cost: false,
      budget_cents: 100,
      max_cases: 3,
      threshold: 0.9,
      concurrency: 2,
    });
    expect(wrapper.text()).toContain('"summary"');
  });

  it('requires visible budget acknowledgement for dataset live assertions', async () => {
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    await wrapper
      .find('[data-testid="tribunal-dataset-live-assertions"]')
      .setValue(true);

    expect(
      wrapper.find('[data-testid="tribunal-acknowledge-cost"]').exists()
    ).toBe(true);
    expect(
      findButton(
        wrapper,
        'CAPTAIN.EVALUATIONS.TRIBUNAL.DATASET_BUTTON'
      ).attributes('disabled')
    ).toBeDefined();

    await wrapper
      .find('[data-testid="tribunal-acknowledge-cost"]')
      .setValue(true);
    await findButton(
      wrapper,
      'CAPTAIN.EVALUATIONS.TRIBUNAL.DATASET_BUTTON'
    ).trigger('click');
    await flushPromises();

    expect(runDatasetMock).toHaveBeenCalledWith(
      expect.objectContaining({
        allow_live_assertions: true,
        acknowledge_llm_cost: true,
      })
    );
  });

  it('generates red-team prompts from the page', async () => {
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    await wrapper
      .find('[data-testid="red-team-prompt"]')
      .setValue('unsafe prompt');

    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.RED_TEAM.BUTTON').trigger(
      'click'
    );
    await flushPromises();

    expect(generateRedTeamMock).toHaveBeenCalledWith({
      prompt: 'unsafe prompt',
      categories: ['encoding', 'injection', 'jailbreak'],
    });
    expect(wrapper.text()).toContain('encoded attack');
  });
});
