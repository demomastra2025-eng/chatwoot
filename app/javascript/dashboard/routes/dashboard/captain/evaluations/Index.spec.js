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
        id: 'captain.voice_scenarios',
        label: 'AI Voice scenario integrity',
        description: 'Voice scenarios',
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
      {
        id: 'captain.scenario_simulation',
        label: 'Captain live scenario simulation',
        description: 'Live scenarios',
        deterministic: false,
        live_model: true,
        default_enabled: false,
      },
      {
        id: 'captain.scenario_red_team',
        label: 'Captain adaptive red-team simulation',
        description: 'Live red-team',
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
          cases: [
            {
              id: 'voice.trace_healthy',
              description: 'Trace stays healthy',
              status: 'pass',
              duration_ms: 4,
              tags: ['voice'],
              artifact: {
                usage: {
                  providers: ['openrouter'],
                  models: ['openai/gpt-5.4-mini'],
                  token_totals: { total_tokens: 42 },
                  estimated_cost: 0.00012,
                },
                timeline: [
                  {
                    index: 0,
                    type: 'message',
                    role: 'assistant',
                    preview: 'Короткий ответ',
                  },
                ],
              },
            },
          ],
        },
      ],
      release_gate: {
        status: 'pass',
        passed: true,
        required_pack_ids: ['captain.ai_voice_trace'],
        failures: [],
        summary: {
          schema_invalid_count: 0,
          tool_failure_count: 0,
          no_content_count: 0,
          catalog_stale_count: 0,
        },
      },
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
    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.PACK_COPY.SCENARIO_SIMULATION.LABEL'
    );
    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.PACK_COPY.SCENARIO_RED_TEAM.LABEL'
    );
    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.PACK_COPY.VOICE_SCENARIOS.LABEL'
    );
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.PACKS.DETERMINISTIC');
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.PACKS.LLM_MODEL');
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.PACK_GROUPS.LIVE');
  });

  it('runs the default selected eval packs and renders the result summary', async () => {
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.RUN_EVALS').trigger('click');
    await flushPromises();

    expect(runMock).toHaveBeenCalledWith({
      pack_ids: [
        'captain.ai_voice_trace',
        'captain.voice_scenarios',
        'captain.event_contract_trace',
      ],
      acknowledge_llm_cost: false,
      budget_cents: 100,
      max_cases: 3,
    });
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.RESULT_STATUS.PASS');
    expect(wrapper.text()).toContain('12 / 12');
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.RELEASE_GATE.TITLE');
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.RELEASE_GATE.PASS');
    expect(wrapper.text()).toContain('captain.ai_voice_trace');
    expect(wrapper.text()).toContain('voice.trace_healthy');
    expect(wrapper.text()).toContain('openrouter');
    expect(wrapper.text()).toContain('openai/gpt-5.4-mini');
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.RESULTS.TOKENS');
  });

  it('renders pass rate, failed scenarios, gate categories, cost, and duration in eval reports', async () => {
    runMock.mockResolvedValueOnce({
      data: {
        result: {
          status: 'fail',
          suite_count: 1,
          total_count: 4,
          passed_count: 3,
          failed_count: 1,
          error_count: 0,
          pass_rate: 0.75,
          duration_ms: 88,
          estimated_cost: 0.00042,
          failed_scenarios: [
            {
              suite_id: 'captain.scenarios',
              id: 'openrouter.tool_result_requires_final_answer',
              status: 'fail',
              duration_ms: 31,
              failures: ['assistant response missing after last user message'],
            },
          ],
          suites: [
            {
              suite_id: 'captain.scenarios',
              status: 'fail',
              total_count: 4,
              passed_count: 3,
              failed_count: 1,
              error_count: 0,
              pass_rate: 0.75,
              cases: [
                {
                  id: 'openrouter.tool_result_requires_final_answer',
                  status: 'fail',
                  duration_ms: 31,
                  failures: [
                    'assistant response missing after last user message',
                  ],
                  tags: ['openrouter', 'tool_no_final_answer'],
                  artifact: {
                    usage: {
                      providers: ['openrouter'],
                      models: ['openai/gpt-5.4-mini'],
                      token_totals: { total_tokens: 42 },
                      estimated_cost: 0.00042,
                    },
                  },
                },
              ],
            },
          ],
          release_gate: {
            status: 'fail',
            passed: false,
            required_pack_ids: ['captain.scenarios'],
            failures: [
              'schema invalid eval cases exceeded gate: 1 > 0',
              'tool failure eval cases exceeded gate: 1 > 0',
            ],
            summary: {
              pass_rate: 0.75,
              schema_invalid_count: 1,
              tool_failure_count: 1,
              zero_completion_count: 1,
              no_content_count: 0,
              catalog_stale_count: 0,
            },
          },
        },
      },
    });
    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.RUN_EVALS').trigger('click');
    await flushPromises();

    expect(wrapper.find('[data-testid="eval-pass-rate"]').text()).toContain(
      '75%'
    );
    expect(
      wrapper.find('[data-testid="eval-failed-scenarios"]').text()
    ).toContain('openrouter.tool_result_requires_final_answer');
    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.RELEASE_GATE.SCHEMA_INVALID'
    );
    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.RELEASE_GATE.TOOL_FAILURE'
    );
    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.RELEASE_GATE.ZERO_COMPLETION'
    );
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.RESULTS.COST');
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.RESULTS.DURATION_MS');
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
            'captain.voice_scenarios',
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
      .findAll('[data-testid="eval-pack-checkbox"]')[3]
      .setValue(true);
    await wrapper.find('[data-testid="eval-budget-cents"]').setValue('75');
    await wrapper.find('[data-testid="eval-max-cases"]').setValue('2');
    await wrapper.find('[data-testid="eval-acknowledge-cost"]').setValue(true);

    await findButton(wrapper, 'CAPTAIN.EVALUATIONS.RUN_EVALS').trigger('click');
    await flushPromises();

    expect(runMock).toHaveBeenCalledWith({
      pack_ids: [
        'captain.ai_voice_trace',
        'captain.voice_scenarios',
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
          result: {
            status: 'pass',
            suite_count: 1,
            total_count: 1,
            passed_count: 1,
            failed_count: 0,
            error_count: 0,
            suites: [
              {
                suite_id: 'captain.ai_voice_trace',
                status: 'pass',
                total_count: 1,
                passed_count: 1,
                failed_count: 0,
                error_count: 0,
                case_summaries: [{ id: 'safe_case', status: 'pass' }],
                cases: [{ input: 'secret customer prompt' }],
              },
            ],
          },
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
    expect(wrapper.text()).toContain('safe_case');
    expect(wrapper.text()).not.toContain('secret customer prompt');
  });

  it('renders compact eval run history from catalog without raw result data', async () => {
    getMock.mockResolvedValueOnce({
      data: {
        ...catalogPayload.data,
        recent_eval_runs: [
          {
            id: 456,
            status: 'failed',
            result: { cases: [{ input: 'secret prompt from history' }] },
            result_summary: {
              suite_count: 2,
              passed_count: 1,
              failed_count: 1,
              suite_ids: [
                'captain.ai_voice_trace',
                'captain.product_case_correctness',
              ],
            },
          },
        ],
      },
    });

    const wrapper = mount(EvaluationsIndex);
    await flushPromises();

    expect(wrapper.find('[data-testid="eval-run-history"]').exists()).toBe(
      true
    );
    expect(wrapper.text()).toContain('CAPTAIN.EVALUATIONS.RUN.HISTORY');
    expect(wrapper.text()).toContain(
      'CAPTAIN.EVALUATIONS.RUN.LAST_RUN_WITH_ID'
    );
    expect(wrapper.text()).toContain('captain.product_case_correctness');
    expect(wrapper.text()).not.toContain('secret prompt from history');
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
