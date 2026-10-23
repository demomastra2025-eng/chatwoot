import { describe, expect, it } from 'vitest';
import {
  CONNECTION_STATUS,
  getTelegramPersonalConnectionStatus,
  getWhatsappWebConnectionStatus,
} from './connectionStatus';

const whatsappWebInbox = (status, connectionState, extra = {}) => ({
  channel_type: 'Channel::WhatsappWeb',
  additional_attributes: {
    evolution: { status, connection_state: connectionState, ...extra },
  },
});

describe('getWhatsappWebConnectionStatus', () => {
  it('is connected only when the session is connected and open', () => {
    expect(
      getWhatsappWebConnectionStatus(whatsappWebInbox('connected', 'open'))
    ).toBe(CONNECTION_STATUS.CONNECTED);
  });

  it.each([
    ['creating', ''],
    ['waiting_for_qr', ''],
    ['qr_ready', 'close'],
    ['qr_scanned', ''],
    ['reconnecting', 'close'],
    ['connected', 'connecting'],
  ])('is connecting for %s / %s', (status, connectionState) => {
    expect(
      getWhatsappWebConnectionStatus(whatsappWebInbox(status, connectionState))
    ).toBe(CONNECTION_STATUS.CONNECTING);
  });

  it.each([
    ['disconnected', 'close'],
    ['failed', ''],
    ['connected', 'close'],
    ['', ''],
  ])('has no connection for %s / %s', (status, connectionState) => {
    expect(
      getWhatsappWebConnectionStatus(whatsappWebInbox(status, connectionState))
    ).toBe(CONNECTION_STATUS.DISCONNECTED);
  });

  it('has no connection while the channel is being deleted', () => {
    expect(
      getWhatsappWebConnectionStatus({
        ...whatsappWebInbox('connected', 'open'),
        deleting: true,
      })
    ).toBe(CONNECTION_STATUS.DISCONNECTED);
  });
});

describe('getTelegramPersonalConnectionStatus', () => {
  it('is connected when authorized and the connection is up', () => {
    expect(
      getTelegramPersonalConnectionStatus({
        isConnected: true,
        lifecycleState: 'connected',
        connectionState: 'connected',
      })
    ).toBe(CONNECTION_STATUS.CONNECTED);
  });

  it('is connecting while reconnecting or while the login is being finished', () => {
    ['code_sent', 'qr_ready', 'password_required'].forEach(lifecycleState => {
      expect(
        getTelegramPersonalConnectionStatus({
          isConnected: false,
          lifecycleState,
          connectionState: 'disconnected',
        })
      ).toBe(CONNECTION_STATUS.CONNECTING);
    });
    expect(
      getTelegramPersonalConnectionStatus({
        isConnected: true,
        lifecycleState: 'connected',
        connectionState: 'connecting',
      })
    ).toBe(CONNECTION_STATUS.CONNECTING);
  });

  it.each([
    ['pending_auth', 'disconnected'],
    ['qr_expired', 'disconnected'],
    ['failed', 'failed'],
    ['disconnected', 'auth_required'],
  ])('has no connection for %s / %s', (lifecycleState, connectionState) => {
    expect(
      getTelegramPersonalConnectionStatus({
        isConnected: false,
        lifecycleState,
        connectionState,
      })
    ).toBe(CONNECTION_STATUS.DISCONNECTED);
  });

  it('has no connection when authorized but the connection is down', () => {
    expect(
      getTelegramPersonalConnectionStatus({
        isConnected: true,
        lifecycleState: 'connected',
        connectionState: 'flood_wait',
      })
    ).toBe(CONNECTION_STATUS.DISCONNECTED);
  });
});
