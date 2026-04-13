import {
  WHATSAPP_WEB_SIDEBAR_STATUS_POLL_INTERVAL,
  getWhatsappWebState,
  hasWhatsappWebConnectionIssue,
  isInboxPendingDeletion,
  isWhatsappWebConnected,
  isWhatsappWebInbox,
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
    expect(hasWhatsappWebConnectionIssue(reconnectingInbox)).toBe(false);
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
});
