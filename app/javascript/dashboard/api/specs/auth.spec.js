import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../store/utils/api', () => ({
  clearCookiesOnLogout: vi.fn(),
  deleteIndexedDBOnLogout: vi.fn(),
  handleSessionReplaced: vi.fn(),
}));

import authAPI from '../auth';
import {
  clearCookiesOnLogout,
  deleteIndexedDBOnLogout,
  handleSessionReplaced,
} from '../../store/utils/api';

describe('#authAPI.logout', () => {
  const originalAxios = global.axios;
  const axiosMock = {
    delete: vi.fn(),
  };

  beforeEach(() => {
    global.axios = axiosMock;
    vi.clearAllMocks();
  });

  afterEach(() => {
    global.axios = originalAxios;
  });

  it('forces relogin when the session was replaced elsewhere', async () => {
    const staleSessionResponse = {
      status: 401,
      data: {
        code: 'session_replaced',
        message: 'Your account was signed in from another device.',
      },
    };
    axiosMock.delete.mockRejectedValue({ response: staleSessionResponse });

    const response = await authAPI.logout();

    expect(handleSessionReplaced).toHaveBeenCalledWith(
      staleSessionResponse.data
    );
    expect(clearCookiesOnLogout).not.toHaveBeenCalled();
    expect(deleteIndexedDBOnLogout).not.toHaveBeenCalled();
    expect(response).toEqual(staleSessionResponse);
  });

  it('clears local auth state when the logout token is already stale', async () => {
    const expiredLogoutResponse = {
      status: 404,
      data: { success: false },
    };
    axiosMock.delete.mockRejectedValue({ response: expiredLogoutResponse });

    const response = await authAPI.logout();

    expect(deleteIndexedDBOnLogout).toHaveBeenCalledTimes(1);
    expect(clearCookiesOnLogout).toHaveBeenCalledTimes(1);
    expect(handleSessionReplaced).not.toHaveBeenCalled();
    expect(response).toEqual(expiredLogoutResponse);
  });
});
