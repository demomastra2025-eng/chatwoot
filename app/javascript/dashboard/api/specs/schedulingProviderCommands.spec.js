import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import SchedulingProviderCommandsAPI from '../scheduling/providerCommands';
import ApiClient from '../ApiClient';

describe('#SchedulingProviderCommandsAPI', () => {
  const originalAxios = window.axios;
  const originalPath = window.location.pathname;
  const axiosMock = {
    get: vi.fn(() => Promise.resolve()),
    post: vi.fn(() => Promise.resolve()),
  };

  beforeEach(() => {
    window.axios = axiosMock;
    window.history.pushState({}, '', '/app/accounts/1');
    vi.clearAllMocks();
  });

  afterEach(() => {
    window.axios = originalAxios;
    window.history.pushState({}, '', originalPath);
  });

  it('creates an account-scoped API client', () => {
    expect(SchedulingProviderCommandsAPI).toBeInstanceOf(ApiClient);
  });

  it('creates, confirms, and fetches provider commands', () => {
    SchedulingProviderCommandsAPI.create({ operation: 'remove_reception' });
    SchedulingProviderCommandsAPI.confirm(41);
    SchedulingProviderCommandsAPI.get(41);

    expect(axiosMock.post).toHaveBeenNthCalledWith(
      1,
      '/api/v1/accounts/1/scheduling/provider_commands',
      { operation: 'remove_reception' }
    );
    expect(axiosMock.post).toHaveBeenNthCalledWith(
      2,
      '/api/v1/accounts/1/scheduling/provider_commands/41/confirm'
    );
    expect(axiosMock.get).toHaveBeenCalledWith(
      '/api/v1/accounts/1/scheduling/provider_commands/41'
    );
  });

  it('scopes command actions when a provider is supplied', () => {
    SchedulingProviderCommandsAPI.confirm(41, { provider: 'medelement' });
    SchedulingProviderCommandsAPI.get(41, { provider: 'medelement' });
    SchedulingProviderCommandsAPI.patientCandidates(41, {
      provider: 'medelement',
    });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/accounts/1/scheduling/provider_commands/41/confirm',
      { provider: 'medelement' }
    );
    expect(axiosMock.get).toHaveBeenNthCalledWith(
      1,
      '/api/v1/accounts/1/scheduling/provider_commands/41',
      { params: { provider: 'medelement' } }
    );
    expect(axiosMock.get).toHaveBeenNthCalledWith(
      2,
      '/api/v1/accounts/1/scheduling/provider_commands/41/patient_candidates',
      { params: { provider: 'medelement' } }
    );
  });
});
