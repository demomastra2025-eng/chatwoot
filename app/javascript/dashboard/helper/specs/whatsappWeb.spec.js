import {
  getWhatsappWebDisplayLabel,
  hasWhatsappWebNonOpenState,
  WHATSAPP_WEB_SIDEBAR_STATUS_POLL_INTERVAL,
  getWhatsappWebState,
  getWhatsappWebConnectionState,
  getWhatsappWebLifecycleState,
  hasWhatsappWebAuthenticationArtifacts,
  hasWhatsappWebConnectionIssue,
  hasWhatsappWebImportInProgress,
  isInboxPendingDeletion,
  isWhatsappWebConnected,
  isWhatsappWebInbox,
  isWhatsappWebReconnecting,
  isWhatsappWebTransientState,
  getWhatsappWebImportAlertKey,
  shouldRequestWhatsappWebQrAfterReconnect,
  shouldRequestWhatsappWebQrAfterRepair,
} from '../whatsappWeb';

describe('#whatsappWeb helpers', () => {
  const whatsappWebInbox = {
    channel_type: 'Channel::WhatsappWeb',
    additional_attributes: {
      evolution: {
        status: 'connected',
        connection_state: 'open',
      },
    },
  };

  it('returns the configured sidebar polling interval', () => {
    expect(WHATSAPP_WEB_SIDEBAR_STATUS_POLL_INTERVAL).toBe(30 * 1000);
  });

  it('returns the embedded evolution state', () => {
    expect(getWhatsappWebState(whatsappWebInbox)).toEqual({
      status: 'connected',
      connection_state: 'open',
    });
  });

  it('returns an empty object when evolution state is missing', () => {
    expect(getWhatsappWebState({})).toEqual({});
  });

  it('detects whatsapp web inboxes', () => {
    expect(isWhatsappWebInbox(whatsappWebInbox)).toBe(true);
    expect(isWhatsappWebInbox({ channel_type: 'Channel::Api' })).toBe(false);
  });

  it('treats connected whatsapp web inboxes as healthy', () => {
    expect(isWhatsappWebConnected(whatsappWebInbox)).toBe(true);
    expect(hasWhatsappWebConnectionIssue(whatsappWebInbox)).toBe(false);
  });

  it('prefers live evolution state over stale top-level inbox lifecycle state', () => {
    const waitingForQrInbox = {
      ...whatsappWebInbox,
      lifecycle_state: 'connected',
      connection_state: 'open',
      additional_attributes: {
        evolution: {
          status: 'waiting_for_qr',
          connection_state: 'connecting',
        },
      },
    };

    expect(getWhatsappWebLifecycleState(waitingForQrInbox)).toBe(
      'waiting_for_qr'
    );
    expect(getWhatsappWebConnectionState(waitingForQrInbox)).toBe('connecting');
    expect(isWhatsappWebConnected(waitingForQrInbox)).toBe(false);
    expect(hasWhatsappWebNonOpenState(waitingForQrInbox)).toBe(true);
  });

  it('treats disconnected whatsapp web inboxes as issues', () => {
    const disconnectedInbox = {
      ...whatsappWebInbox,
      additional_attributes: {
        evolution: {
          status: 'disconnected',
          connection_state: 'close',
        },
      },
    };

    expect(isWhatsappWebConnected(disconnectedInbox)).toBe(false);
    expect(hasWhatsappWebNonOpenState(disconnectedInbox)).toBe(true);
    expect(hasWhatsappWebConnectionIssue(disconnectedInbox)).toBe(true);
  });

  it('does not flag reconnecting whatsapp web inboxes as hard failures', () => {
    const reconnectingInbox = {
      ...whatsappWebInbox,
      additional_attributes: {
        evolution: {
          status: 'reconnecting',
          connection_state: 'reconnecting',
        },
      },
    };

    expect(isWhatsappWebConnected(reconnectingInbox)).toBe(false);
    expect(hasWhatsappWebNonOpenState(reconnectingInbox)).toBe(true);
    expect(isWhatsappWebReconnecting(reconnectingInbox)).toBe(true);
    expect(isWhatsappWebTransientState(reconnectingInbox)).toBe(true);
    expect(hasWhatsappWebConnectionIssue(reconnectingInbox)).toBe(false);
  });

  it('treats qr and connecting states as alertable transient states', () => {
    const qrReadyInbox = {
      ...whatsappWebInbox,
      additional_attributes: {
        evolution: {
          status: 'qr_ready',
          connection_state: 'connecting',
        },
      },
    };

    expect(hasWhatsappWebNonOpenState(qrReadyInbox)).toBe(true);
    expect(isWhatsappWebTransientState(qrReadyInbox)).toBe(true);
    expect(hasWhatsappWebConnectionIssue(qrReadyInbox)).toBe(false);
  });

  it('builds a human-friendly inbox label for alerts', () => {
    const namedInbox = {
      ...whatsappWebInbox,
      id: 42,
      name: 'Support WA',
      phone_number: '+77001234567',
    };

    expect(getWhatsappWebDisplayLabel(namedInbox)).toBe(
      'Support WA (+77001234567)'
    );
    expect(
      getWhatsappWebDisplayLabel({
        ...whatsappWebInbox,
        id: 43,
        phone_number: '+77007654321',
      })
    ).toBe('+77007654321');
  });

  it('detects stored qr or pairing auth artifacts', () => {
    const qrReadyInbox = {
      ...whatsappWebInbox,
      additional_attributes: {
        evolution: {
          status: 'qr_ready',
          connection_state: 'connecting',
          qrcode: {
            pairingCode: 'ABCD1234',
          },
        },
      },
    };

    expect(hasWhatsappWebAuthenticationArtifacts(qrReadyInbox)).toBe(true);
  });

  it('requests a fresh qr after repair when the session is still disconnected without auth artifacts', () => {
    const disconnectedInbox = {
      ...whatsappWebInbox,
      additional_attributes: {
        evolution: {
          status: 'disconnected',
          connection_state: 'close',
        },
      },
    };

    expect(shouldRequestWhatsappWebQrAfterRepair(disconnectedInbox)).toBe(true);
  });

  it('does not request a fresh qr after repair while the provider is still reconnecting', () => {
    const reconnectingInbox = {
      ...whatsappWebInbox,
      additional_attributes: {
        evolution: {
          status: 'reconnecting',
          connection_state: 'reconnecting',
        },
      },
    };

    expect(shouldRequestWhatsappWebQrAfterRepair(reconnectingInbox)).toBe(
      false
    );
    expect(shouldRequestWhatsappWebQrAfterReconnect(reconnectingInbox)).toBe(
      true
    );
  });

  it('ignores non-whatsapp inboxes for connection alerts', () => {
    const facebookInbox = {
      channel_type: 'Channel::FacebookPage',
      additional_attributes: {
        evolution: {
          status: 'failed',
          connection_state: 'close',
        },
      },
    };

    expect(isWhatsappWebConnected(facebookInbox)).toBe(false);
    expect(hasWhatsappWebConnectionIssue(facebookInbox)).toBe(false);
  });

  it('treats deleting whatsapp web inboxes as pending deletion instead of unhealthy', () => {
    const deletingInbox = {
      ...whatsappWebInbox,
      deleting: true,
      lifecycle_state: 'deleting',
      additional_attributes: {
        evolution: {
          status: 'deleting',
          connection_state: 'close',
        },
      },
    };

    expect(isInboxPendingDeletion(deletingInbox)).toBe(true);
    expect(isWhatsappWebConnected(deletingInbox)).toBe(false);
    expect(hasWhatsappWebConnectionIssue(deletingInbox)).toBe(false);
  });

  it('detects active whatsapp web imports and builds a stable alert key', () => {
    const importingInbox = {
      ...whatsappWebInbox,
      id: 99,
      additional_attributes: {
        evolution: {
          status: 'connected',
          connection_state: 'open',
          history_sync_in_progress: true,
          history_sync_requested_at: '2026-04-14T10:00:00Z',
        },
      },
    };

    expect(hasWhatsappWebImportInProgress(importingInbox)).toBe(true);
    expect(getWhatsappWebImportAlertKey(importingInbox)).toBe(
      'whatsapp:import:99:2026-04-14T10:00:00Z'
    );
  });
});
