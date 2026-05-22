import ApiClient from '../ApiClient';
import captainEvaluationsAPI from '../captain/evaluations';

describe('#CaptainEvaluationsAPI', () => {
  const originalAxios = window.axios;
  const originalPathname = window.location.pathname;
  const axiosMock = {
    get: vi.fn(() => Promise.resolve()),
    post: vi.fn(() => Promise.resolve()),
  };

  beforeEach(() => {
    window.axios = axiosMock;
    window.history.pushState({}, '', '/app/accounts/6/captain/evaluations');
    axiosMock.get.mockClear();
    axiosMock.post.mockClear();
  });

  afterEach(() => {
    window.axios = originalAxios;
    window.history.pushState({}, '', originalPathname);
  });

  it('creates correct instance', () => {
    expect(captainEvaluationsAPI).toBeInstanceOf(ApiClient);
  });

  it('fetches the account-scoped evaluation catalog', () => {
    captainEvaluationsAPI.get();

    expect(axiosMock.get).toHaveBeenCalledWith(
      '/api/v1/accounts/6/captain/evaluations'
    );
  });

  it('runs any selected packs through the unified account-scoped endpoint', () => {
    captainEvaluationsAPI.run({
      pack_ids: ['captain.ai_voice_trace', 'captain.conversation_completion'],
      acknowledge_llm_cost: true,
      budget_cents: 75,
      max_cases: 2,
    });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/6/captain/evaluations/run',
      {
        pack_ids: ['captain.ai_voice_trace', 'captain.conversation_completion'],
        acknowledge_llm_cost: true,
        budget_cents: 75,
        max_cases: 2,
      }
    );
  });

  it('fetches a queued eval run status through the account-scoped endpoint', () => {
    captainEvaluationsAPI.getRun(123);

    expect(axiosMock.get).toHaveBeenCalledWith(
      '/api/v1/accounts/6/captain/evaluations/run_status',
      { params: { run_id: 123 } }
    );
  });

  it('exports a conversation as an eval fixture preview through the account-scoped endpoint', () => {
    captainEvaluationsAPI.importConversation({ inbox_id: 57, display_id: 481 });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/6/captain/evaluations/import_conversation',
      { inbox_id: 57, display_id: 481 }
    );
  });

  it('runs generic Tribunal datasets through the account-scoped endpoint', () => {
    captainEvaluationsAPI.runDataset({
      files: ['config/llm_evals/datasets/captain_sample.yml'],
      format: 'json',
      strict: true,
    });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/6/captain/evaluations/run_dataset',
      {
        files: ['config/llm_evals/datasets/captain_sample.yml'],
        format: 'json',
        strict: true,
      }
    );
  });

  it('generates red-team prompts through the account-scoped endpoint', () => {
    captainEvaluationsAPI.generateRedTeam({
      prompt: 'unsafe prompt',
      categories: ['encoding'],
    });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/6/captain/evaluations/red_team',
      { prompt: 'unsafe prompt', categories: ['encoding'] }
    );
  });
});
