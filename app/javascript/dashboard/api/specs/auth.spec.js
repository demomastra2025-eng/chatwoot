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

describe('#authAPI.profileUpdate', () => {
  const originalAxios = global.axios;
  const axiosMock = {
    put: vi.fn(() => Promise.resolve()),
  };

  beforeEach(() => {
    global.axios = axiosMock;
    vi.clearAllMocks();
  });

  afterEach(() => {
    global.axios = originalAxios;
  });

  it('does not clear display name on partial profile updates', () => {
    authAPI.profileUpdate({ message_signature: 'Regards' });

    const [, payload] = axiosMock.put.mock.calls[0];
    expect(payload.get('profile[message_signature]')).toBe('Regards');
    expect(payload.has('profile[display_name]')).toBe(false);
  });

  it('sends display name when profile details include it', () => {
    authAPI.profileUpdate({
      name: 'Jane',
      email: 'jane@example.com',
      displayName: 'Support Jane',
    });

    const [, payload] = axiosMock.put.mock.calls[0];
    expect(payload.get('profile[name]')).toBe('Jane');
    expect(payload.get('profile[email]')).toBe('jane@example.com');
    expect(payload.get('profile[display_name]')).toBe('Support Jane');
  });
});

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
