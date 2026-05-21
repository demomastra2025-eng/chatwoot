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

  it('runs deterministic packs through the account-scoped endpoint', () => {
    captainEvaluationsAPI.run({ pack_ids: ['captain.ai_voice_trace'] });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/6/captain/evaluations/run',
      { pack_ids: ['captain.ai_voice_trace'] }
    );
  });

  it('runs live packs through the controlled account-scoped endpoint', () => {
    captainEvaluationsAPI.runLive({
      pack_ids: ['captain.conversation_completion'],
      acknowledge_live_cost: true,
      budget_cents: 75,
      max_cases: 2,
    });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/6/captain/evaluations/run_live',
      {
        pack_ids: ['captain.conversation_completion'],
        acknowledge_live_cost: true,
        budget_cents: 75,
        max_cases: 2,
      }
    );
  });

  it('fetches a live run status through the account-scoped endpoint', () => {
    captainEvaluationsAPI.getLiveRun(123);

    expect(axiosMock.get).toHaveBeenCalledWith(
      '/api/v1/accounts/6/captain/evaluations/live_run',
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
});
