import {
  TELEGRAM_PERSONAL_SIDEBAR_STATUS_POLL_INTERVAL,
  getTelegramPersonalDisplayLabel,
  getTelegramPersonalImportAlertKey,
  getTelegramPersonalState,
  hasTelegramPersonalConnectionIssue,
  hasTelegramPersonalImportInProgress,
  hasTelegramPersonalNonConnectedState,
  isTelegramPersonalConnected,
  isTelegramPersonalInbox,
  isTelegramPersonalReconnecting,
  isTelegramPersonalTransientState,
} from '../telegramPersonal';

describe('#telegramPersonal helpers', () => {
  const telegramPersonalInbox = {
    channel_type: 'Channel::TelegramPersonal',
    connection_state: 'connected',
    lifecycle_state: 'connected',
    runtime_state: {
      auth_state: 'authorized',
      connection_state: 'connected',
      lifecycle_state: 'connected',
    },
  };

  it('returns the configured sidebar polling interval', () => {
    expect(TELEGRAM_PERSONAL_SIDEBAR_STATUS_POLL_INTERVAL).toBe(30 * 1000);
  });

  it('returns runtime state when it is present', () => {
    expect(getTelegramPersonalState(telegramPersonalInbox)).toEqual(
      telegramPersonalInbox.runtime_state
    );
  });

  it('detects telegram personal inboxes', () => {
    expect(isTelegramPersonalInbox(telegramPersonalInbox)).toBe(true);
    expect(isTelegramPersonalInbox({ channel_type: 'Channel::Api' })).toBe(
      false
    );
  });

  it('treats authorized connected inboxes as healthy', () => {
    expect(isTelegramPersonalConnected(telegramPersonalInbox)).toBe(true);
    expect(hasTelegramPersonalConnectionIssue(telegramPersonalInbox)).toBe(
      false
    );
  });

  it('does not flag setup lifecycle states as hard failures', () => {
    const pendingAuthInbox = {
      ...telegramPersonalInbox,
      connection_state: 'disconnected',
      lifecycle_state: 'pending_auth',
      runtime_state: {
        auth_state: 'pending_auth',
        connection_state: 'disconnected',
        lifecycle_state: 'pending_auth',
      },
    };

    expect(isTelegramPersonalConnected(pendingAuthInbox)).toBe(false);
    expect(hasTelegramPersonalConnectionIssue(pendingAuthInbox)).toBe(false);
  });

  it('flags disconnected connected-state inboxes as issues', () => {
    const failedInbox = {
      ...telegramPersonalInbox,
      connection_state: 'failed',
      lifecycle_state: 'connected',
      runtime_state: {
        auth_state: 'authorized',
        connection_state: 'failed',
        lifecycle_state: 'connected',
      },
    };

    expect(isTelegramPersonalConnected(failedInbox)).toBe(false);
    expect(hasTelegramPersonalConnectionIssue(failedInbox)).toBe(true);
  });

  it('detects reconnecting telegram personal inboxes as transient non-connected states', () => {
    const reconnectingInbox = {
      ...telegramPersonalInbox,
      connection_state: 'reconnecting',
      lifecycle_state: 'reconnecting',
      runtime_state: {
        auth_state: 'authorized',
        connection_state: 'reconnecting',
        lifecycle_state: 'reconnecting',
      },
    };

    expect(hasTelegramPersonalNonConnectedState(reconnectingInbox)).toBe(true);
    expect(isTelegramPersonalReconnecting(reconnectingInbox)).toBe(true);
    expect(isTelegramPersonalTransientState(reconnectingInbox)).toBe(true);
  });

  it('detects active telegram personal imports and builds display metadata', () => {
    const importingInbox = {
      ...telegramPersonalInbox,
      id: 13,
      name: 'TG Support',
      phone_number: '+77001234567',
      runtime_state: {
        auth_state: 'authorized',
        connection_state: 'connected',
        lifecycle_state: 'connected',
        history_sync_state: 'running',
        history_sync_requested_at: '2026-04-14T10:00:00Z',
        contacts_sync_state: 'scheduled',
        contacts_sync_requested_at: '2026-04-14T10:05:00Z',
      },
    };

    expect(hasTelegramPersonalImportInProgress(importingInbox)).toBe(true);
    expect(getTelegramPersonalDisplayLabel(importingInbox)).toBe(
      'TG Support (+77001234567)'
    );
    expect(getTelegramPersonalImportAlertKey(importingInbox)).toBe(
      'telegram-personal:import:13:2026-04-14T10:00:00Z:2026-04-14T10:05:00Z'
    );
  });
});
