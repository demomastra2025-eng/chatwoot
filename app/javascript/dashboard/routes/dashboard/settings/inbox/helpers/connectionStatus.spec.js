import { describe, expect, it } from 'vitest';
import {
  CONNECTION_STATUS,
  getTelegramPersonalConnectionStatus,
  getWeixinConnectionStatus,
  getWhatsappWebConnectionStatus,
} from './connectionStatus';
import { getInboxListStatus } from './inboxListStatus';

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

  // A failed reconnect only marks the lifecycle as failed and leaves the
  // connection on «connecting», so a failed channel must not look like it is
  // still connecting.
  it.each([
    ['failed', 'connecting'],
    ['failed', 'reconnecting'],
    ['error', 'connecting'],
    ['degraded', 'reconnecting'],
    ['disconnected', 'connecting'],
    ['logged_out', 'reconnecting'],
    ['qr_expired', 'connecting'],
    [' Failed ', 'Connecting'],
  ])(
    'has no connection for a broken session (%s / %s) even if the connection is still starting',
    (status, connectionState) => {
      expect(
        getWhatsappWebConnectionStatus(
          whatsappWebInbox(status, connectionState)
        )
      ).toBe(CONNECTION_STATUS.DISCONNECTED);
    }
  );

  it.each([
    ['failed', 'connecting'],
    ['failed', 'reconnecting'],
    ['failed', ''],
    ['error', 'connecting'],
    ['disconnected', 'connecting'],
    ['connected', 'connecting'],
    ['connected', 'close'],
    ['waiting_for_qr', 'connecting'],
    ['reconnecting', 'close'],
    ['connected', 'open'],
    ['', ''],
  ])(
    'agrees with the channels list about a connection (%s / %s)',
    (status, connectionState) => {
      const inbox = whatsappWebInbox(status, connectionState);
      const listStatus = getInboxListStatus(inbox);

      expect(getWhatsappWebConnectionStatus(inbox) === 'connected').toBe(
        listStatus.id === 'connected'
      );
      // «Нет связи» in the list is never «Подключается…» on the page for a
      // failed or closed session.
      if (
        ['failed', 'error', 'disconnected'].includes(status) &&
        listStatus.id === 'disconnected'
      ) {
        expect(getWhatsappWebConnectionStatus(inbox)).toBe(
          CONNECTION_STATUS.DISCONNECTED
        );
      }
    }
  );

  it('keeps showing a session that is really starting as connecting', () => {
    expect(
      getWhatsappWebConnectionStatus(
        whatsappWebInbox('waiting_for_qr', 'connecting')
      )
    ).toBe(CONNECTION_STATUS.CONNECTING);
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

describe('getWeixinConnectionStatus', () => {
  it('is connected only when the login is complete and the connection is up', () => {
    expect(
      getWeixinConnectionStatus({
        lifecycleState: 'connected',
        connectionState: 'connected',
      })
    ).toBe(CONNECTION_STATUS.CONNECTED);
    expect(getWeixinConnectionStatus({ connectionState: 'connected' })).toBe(
      CONNECTION_STATUS.CONNECTED
    );
  });

  it.each([
    ['qr_ready', 'disconnected'],
    ['qr_scanned', 'disconnected'],
    ['connected', 'connecting'],
  ])('is connecting for %s / %s', (lifecycleState, connectionState) => {
    expect(
      getWeixinConnectionStatus({ lifecycleState, connectionState })
    ).toBe(CONNECTION_STATUS.CONNECTING);
  });

  it.each([
    ['pending_auth', 'disconnected'],
    ['qr_expired', 'auth_required'],
    ['failed', 'failed'],
    ['connected', 'rate_limited'],
    ['disconnected', 'connected'],
    ['', ''],
  ])('has no connection for %s / %s', (lifecycleState, connectionState) => {
    expect(
      getWeixinConnectionStatus({ lifecycleState, connectionState })
    ).toBe(CONNECTION_STATUS.DISCONNECTED);
  });

  it('agrees with the channels list about a connected account', () => {
    const inbox = {
      channel_type: 'Channel::Weixin',
      lifecycle_state: 'connected',
      connection_state: 'connected',
    };

    expect(getInboxListStatus(inbox).id).toBe('connected');
    expect(
      getWeixinConnectionStatus({
        lifecycleState: inbox.lifecycle_state,
        connectionState: inbox.connection_state,
      })
    ).toBe(CONNECTION_STATUS.CONNECTED);
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
