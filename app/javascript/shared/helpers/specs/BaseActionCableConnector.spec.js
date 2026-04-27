import { describe, it, beforeEach, afterEach, expect, vi } from 'vitest';
import BaseActionCableConnector from '../BaseActionCableConnector';
import { createConsumer } from '@rails/actioncable';

vi.mock('@rails/actioncable', () => ({
  createConsumer: vi.fn(() => ({
    subscriptions: {
      create: vi.fn((_params, handlers) => ({
        ...handlers,
        updatePresence: vi.fn(),
      })),
    },
    connection: { isOpen: vi.fn(() => true) },
    disconnect: vi.fn(),
  })),
}));

describe('BaseActionCableConnector', () => {
  const app = {
    $store: {
      getters: {
        getCurrentAccountId: 7,
        getCurrentUserID: 42,
      },
    },
  };

  beforeEach(() => {
    vi.useFakeTimers();
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('passes auth_client_id and websocket host with the current constructor signature', () => {
    const connector = new BaseActionCableConnector(
      app,
      'pubsub-token',
      'client-1',
      'wss://socket.example',
      20000
    );

    expect(createConsumer).toHaveBeenCalledWith('wss://socket.example/cable');
    expect(connector.consumer.subscriptions.create).toHaveBeenCalledWith(
      expect.objectContaining({
        channel: 'RoomChannel',
        pubsub_token: 'pubsub-token',
        auth_client_id: 'client-1',
        account_id: 7,
        user_id: 42,
      }),
      expect.any(Object)
    );
  });

  it('keeps legacy widget signature support for websocket host and presence interval', () => {
    const connector = new BaseActionCableConnector(
      app,
      'pubsub-token',
      'wss://legacy.example',
      30000
    );

    expect(createConsumer).toHaveBeenCalledWith('wss://legacy.example/cable');
    expect(connector.consumer.subscriptions.create).toHaveBeenCalledWith(
      expect.objectContaining({ auth_client_id: null }),
      expect.any(Object)
    );
  });
});
