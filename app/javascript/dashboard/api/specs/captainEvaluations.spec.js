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
});
