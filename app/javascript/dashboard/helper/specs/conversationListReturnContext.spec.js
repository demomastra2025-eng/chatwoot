import { describe, expect, it, vi } from 'vitest';
import {
  conversationListReturnPath,
  rememberConversationListReturnPath,
} from '../conversationListReturnContext';

const createStorage = () => {
  const values = new Map();
  return {
    getItem: vi.fn(key => values.get(key)),
    setItem: vi.fn((key, value) => values.set(key, value)),
  };
};

describe('conversationListReturnContext', () => {
  it('returns history state and stores a reload fallback', () => {
    const storage = createStorage();
    const state = rememberConversationListReturnPath({
      accountId: 1,
      threadId: 7,
      path: '/app/accounts/1/custom_view/9/conversations',
      storage,
    });

    expect(
      conversationListReturnPath({
        accountId: 1,
        threadId: 7,
        historyState: state,
        storage,
      })
    ).toBe('/app/accounts/1/custom_view/9/conversations');
    expect(
      conversationListReturnPath({
        accountId: 1,
        threadId: 7,
        historyState: {},
        storage,
      })
    ).toBe('/app/accounts/1/custom_view/9/conversations');
  });

  it('rejects return paths outside the current account', () => {
    const storage = createStorage();

    expect(
      rememberConversationListReturnPath({
        accountId: 1,
        threadId: 7,
        path: '/app/accounts/2/conversations',
        storage,
      })
    ).toEqual({});
    expect(storage.setItem).not.toHaveBeenCalled();
  });

  it('ignores history state remembered for another thread', () => {
    const storage = createStorage();
    storage.setItem(
      'conversation_list_return_path:1:8',
      '/app/accounts/1/conversations'
    );

    expect(
      conversationListReturnPath({
        accountId: 1,
        threadId: 8,
        historyState: rememberConversationListReturnPath({
          accountId: 1,
          threadId: 7,
          path: '/app/accounts/1/custom_view/9/conversations',
          storage,
        }),
        storage,
      })
    ).toBe('/app/accounts/1/conversations');
  });

  // A full or blocked sessionStorage must never stop the thread from opening.
  describe('when sessionStorage throws', () => {
    const throwingStorage = () => ({
      getItem: vi.fn(() => {
        throw new Error('SecurityError');
      }),
      setItem: vi.fn(() => {
        throw new Error('QuotaExceededError');
      }),
    });

    it('still returns the history state for the navigation', () => {
      const storage = throwingStorage();
      let state;

      expect(() => {
        state = rememberConversationListReturnPath({
          accountId: 1,
          threadId: 7,
          path: '/app/accounts/1/custom_view/9/conversations',
          storage,
        });
      }).not.toThrow();
      expect(storage.setItem).toHaveBeenCalled();
      expect(
        conversationListReturnPath({
          accountId: 1,
          threadId: 7,
          historyState: state,
          storage,
        })
      ).toBe('/app/accounts/1/custom_view/9/conversations');
    });

    it('falls back to no return path when reading fails', () => {
      expect(
        conversationListReturnPath({
          accountId: 1,
          threadId: 7,
          historyState: {},
          storage: throwingStorage(),
        })
      ).toBeUndefined();
    });

    it('survives a window.sessionStorage getter that throws', () => {
      const descriptor = Object.getOwnPropertyDescriptor(
        window,
        'sessionStorage'
      );
      Object.defineProperty(window, 'sessionStorage', {
        configurable: true,
        get: () => {
          throw new Error('SecurityError');
        },
      });

      try {
        expect(
          rememberConversationListReturnPath({
            accountId: 1,
            threadId: 7,
            path: '/app/accounts/1/conversations',
          })
        ).toMatchObject({
          conversationListReturnPath: { path: '/app/accounts/1/conversations' },
        });
        expect(
          conversationListReturnPath({
            accountId: 1,
            threadId: 7,
            historyState: {},
          })
        ).toBeUndefined();
      } finally {
        if (descriptor) {
          Object.defineProperty(window, 'sessionStorage', descriptor);
        } else {
          delete window.sessionStorage;
        }
      }
    });
  });
});
