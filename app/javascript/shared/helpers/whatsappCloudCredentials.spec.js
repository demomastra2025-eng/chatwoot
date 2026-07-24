import {
  clearOneTimeWebhookVerifyToken,
  generateWebhookVerifyToken,
  getOneTimeWebhookVerifyToken,
  storeOneTimeWebhookVerifyToken,
} from './whatsappCloudCredentials';

describe('WhatsApp Cloud credentials helpers', () => {
  it('generates a 32-character token from cryptographically random bytes', () => {
    const cryptoProvider = {
      getRandomValues: vi.fn(bytes => {
        bytes.set(Array.from({ length: 16 }, (_, index) => index));
        return bytes;
      }),
    };

    expect(generateWebhookVerifyToken(cryptoProvider)).toBe(
      '000102030405060708090a0b0c0d0e0f'
    );
    expect(cryptoProvider.getRandomValues).toHaveBeenCalledOnce();
  });

  it('stores the caller-owned verify token only in the current tab storage', () => {
    const values = new Map();
    const storage = {
      setItem: vi.fn((key, value) => values.set(key, value)),
      getItem: vi.fn(key => values.get(key)),
      removeItem: vi.fn(key => values.delete(key)),
    };

    storeOneTimeWebhookVerifyToken(1, 'one-time-verify-token', storage);
    expect(getOneTimeWebhookVerifyToken(1, storage)).toBe(
      'one-time-verify-token'
    );

    clearOneTimeWebhookVerifyToken(1, storage);
    expect(getOneTimeWebhookVerifyToken(1, storage)).toBe('');
  });
});
