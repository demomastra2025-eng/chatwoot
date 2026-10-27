import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import SchedulingMedelementPatientsAPI from '../scheduling/medelementPatients';
import ApiClient from '../ApiClient';

describe('SchedulingMedelementPatientsAPI', () => {
  const originalAxios = window.axios;
  const originalPath = window.location.pathname;
  const axiosMock = { post: vi.fn(() => Promise.resolve()) };

  beforeEach(() => {
    window.axios = axiosMock;
    window.history.pushState({}, '', '/app/accounts/1');
    vi.clearAllMocks();
  });

  afterEach(() => {
    window.axios = originalAxios;
    window.history.pushState({}, '', originalPath);
  });

  it('keeps search text and the chosen token in POST bodies', () => {
    const controller = new AbortController();
    expect(SchedulingMedelementPatientsAPI).toBeInstanceOf(ApiClient);
    SchedulingMedelementPatientsAPI.searchMedelementPatients(
      'Аян',
      controller.signal
    );
    SchedulingMedelementPatientsAPI.importMedelementPatient('opaque-token');

    expect(axiosMock.post).toHaveBeenNthCalledWith(
      1,
      '/api/v1/accounts/1/scheduling/medelement_patients/search',
      { query: 'Аян' },
      { signal: controller.signal }
    );
    expect(axiosMock.post).toHaveBeenNthCalledWith(
      2,
      '/api/v1/accounts/1/scheduling/medelement_patients',
      { token: 'opaque-token' }
    );
  });
});
