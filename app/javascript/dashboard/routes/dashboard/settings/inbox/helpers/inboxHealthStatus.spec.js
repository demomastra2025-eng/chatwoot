import {
  getInboxHealthStatus,
  sanitizeInboxHealthDetail,
} from './inboxHealthStatus';

describe('#getInboxHealthStatus', () => {
  it('returns no status for a missing inbox payload', () => {
    expect(getInboxHealthStatus(null)).toBeNull();
  });

  it('returns connected for a healthy inbox payload', () => {
    expect(getInboxHealthStatus({ id: 1, name: 'Support' })).toMatchObject({
      id: 'connected',
      labelKey: 'INBOX_MGMT.HEALTH_STATUS.CONNECTED',
    });
  });

  it('marks WhatsApp Web connected only when provider status is connected and connection is open', () => {
    expect(
      getInboxHealthStatus({
        channel_type: 'Channel::WhatsappWeb',
        additional_attributes: {
          evolution: { status: 'connected', connection_state: 'open' },
        },
      })
    ).toMatchObject({ id: 'connected', tone: 'teal' });

    expect(
      getInboxHealthStatus({
        channel_type: 'Channel::WhatsappWeb',
        additional_attributes: {
          evolution: { status: 'connected', connection_state: 'connecting' },
        },
      })
    ).toMatchObject({ id: 'pending', tone: 'amber' });
  });

  it('shows WhatsApp Web QR/auth states as pending instead of connected', () => {
    expect(
      getInboxHealthStatus({
        channel_type: 'Channel::WhatsappWeb',
        lifecycle_state: 'connected',
        connection_state: 'open',
        additional_attributes: {
          evolution: {
            status: 'waiting_for_qr',
            connection_state: 'connecting',
          },
        },
      })
    ).toMatchObject({
      id: 'pending',
      labelKey: 'INBOX_MGMT.HEALTH_STATUS.PENDING',
      tone: 'amber',
    });
  });

  it('keeps WhatsApp Web QR lifecycle states pending even when provider connection is close', () => {
    ['creating', 'waiting_for_qr', 'qr_ready', 'qr_scanned'].forEach(status => {
      expect(
        getInboxHealthStatus({
          channel_type: 'Channel::WhatsappWeb',
          additional_attributes: {
            evolution: { status, connection_state: 'close' },
          },
        })
      ).toMatchObject({
        id: 'pending',
        labelKey: 'INBOX_MGMT.HEALTH_STATUS.PENDING',
        tone: 'amber',
      });
    });
  });

  it('prioritizes reauthorization_required from the inbox payload', () => {
    expect(
      getInboxHealthStatus({ id: 1, reauthorization_required: true })
    ).toMatchObject({
      id: 'reauthorization_required',
      tone: 'ruby',
    });
  });

  it('detects reauthorization_required from legacy payload aliases', () => {
    expect(
      getInboxHealthStatus({ id: 1, requires_reauthorization: true })
    ).toMatchObject({ id: 'reauthorization_required' });
  });

  it('detects webhook signature failures without exposing secrets', () => {
    expect(
      getInboxHealthStatus({
        runtime_state: {
          last_error: 'Invalid webhook signature token=sample-value',
        },
      })
    ).toMatchObject({
      id: 'webhook_signature_invalid',
      detail: 'Invalid webhook signature token=[REDACTED]',
    });
  });

  it('prioritizes disconnected runtime state over connected summary state', () => {
    expect(
      getInboxHealthStatus({
        status: 'connected',
        runtime_state: { lifecycle_state: 'pending_auth' },
      })
    ).toMatchObject({ id: 'disconnected' });
  });

  it('detects provider authorization status from provider config', () => {
    expect(
      getInboxHealthStatus({
        provider_config: { authorization_status: 'unauthorized' },
      })
    ).toMatchObject({ id: 'disconnected' });
  });

  it('detects provider unavailable states from runtime payloads', () => {
    expect(
      getInboxHealthStatus({
        additional_attributes: { connection_error: 'Provider unavailable' },
      })
    ).toMatchObject({
      id: 'provider_unavailable',
      tone: 'amber',
    });
  });

  it('treats generic runtime error details as provider unavailable', () => {
    expect(
      getInboxHealthStatus({
        runtime_state: { last_error: 'connection reset' },
      })
    ).toMatchObject({
      id: 'provider_unavailable',
      detail: 'connection reset',
    });
  });

  it('does not expose raw provider JSON in the health detail', () => {
    const detail = JSON.stringify({
      status: 400,
      error: 'Bad Request',
      message: ['The "onelink-waweb-1_77066318623" instance is being deleted'],
    });

    expect(
      getInboxHealthStatus({
        runtime_state: { last_error: detail },
      })
    ).toMatchObject({
      id: 'provider_unavailable',
      detail:
        'Инстанс WhatsApp Web сейчас удаляется или перезапускается. Подождите минуту и повторите подключение.',
    });
  });

  it('does not mark failed or error states as connected', () => {
    expect(
      getInboxHealthStatus({ runtime_state: { connection_state: 'failed' } })
    ).toMatchObject({ id: 'provider_unavailable' });

    expect(
      getInboxHealthStatus({ additional_attributes: { status: 'error' } })
    ).toMatchObject({ id: 'provider_unavailable' });
  });

  it('does not let earlier healthy state mask later failed or error state', () => {
    expect(
      getInboxHealthStatus({
        runtime_state: {
          lifecycle_state: 'connected',
          connection_state: 'failed',
        },
      })
    ).toMatchObject({ id: 'provider_unavailable' });

    expect(
      getInboxHealthStatus({
        provider_config: {
          authorization_status: 'authorized',
          status: 'error',
        },
      })
    ).toMatchObject({ id: 'provider_unavailable' });
  });

  it('treats structured error payloads as provider unavailable', () => {
    expect(
      getInboxHealthStatus({
        runtime_state: { last_error: { code: 'ECONNRESET' } },
      })
    ).toMatchObject({ id: 'provider_unavailable', detail: '' });

    expect(
      getInboxHealthStatus({
        provider_config: { error: ['provider rejected'] },
      })
    ).toMatchObject({ id: 'provider_unavailable', detail: '' });
  });

  it('handles disconnected lifecycle states without crashing on partial payloads', () => {
    expect(
      getInboxHealthStatus({
        runtime_state: { lifecycle_state: 'pending_auth' },
      })
    ).toMatchObject({ id: 'disconnected' });
  });
});

describe('#sanitizeInboxHealthDetail', () => {
  it('extracts user-safe text from provider JSON error strings', () => {
    const detail = JSON.stringify({
      status: 400,
      error: 'Bad Request',
      message: ['The "onelink-waweb-1_77066318623" instance is being deleted'],
    });

    expect(sanitizeInboxHealthDetail(detail)).toBe(
      'Инстанс WhatsApp Web сейчас удаляется или перезапускается. Подождите минуту и повторите подключение.'
    );
  });

  it('redacts sensitive key-value pairs', () => {
    expect(
      sanitizeInboxHealthDetail(
        'auth failed password: sample-value api_key=sample-value'
      )
    ).toBe('auth failed password: [REDACTED] api_key=[REDACTED]');
  });

  it('redacts quoted and JSON-like sensitive values', () => {
    expect(
      sanitizeInboxHealthDetail(
        'auth failed "token": "sample-value" secret="sample-value"'
      )
    ).toBe('auth failed "token": [REDACTED] secret=[REDACTED]');
  });

  it('redacts authorization and cookie header values', () => {
    expect(
      sanitizeInboxHealthDetail(
        'Authorization: Bearer sample-value\nCookie: cw_session=sample-value; other=value'
      )
    ).toBe('Authorization: [REDACTED]\nCookie: [REDACTED]');
  });

  it('redacts sensitive query string values', () => {
    const accessKey = ['access', 'token'].join('_');
    const signatureKey = ['sign', 'ature'].join('');
    const value = 'sample-value';
    const detail = `callback failed https://example.test/hook?${accessKey}=${value}&ok=1&${signatureKey}=${value}`;

    expect(sanitizeInboxHealthDetail(detail)).toBe(
      `callback failed https://example.test/hook?${accessKey}=[REDACTED]&ok=1&${signatureKey}=[REDACTED]`
    );
  });

  it('redacts signature comparison and session values', () => {
    const hubSignatureKey = ['x', 'hub', 'signature', '256'].join('-');
    const sessionKey = ['cw', 'session'].join('_');
    const digest = ['sha', '256'].join('');
    const detail = `${hubSignatureKey}: ${digest}=abcdefghijklmnopqrstuvwxyz signature mismatch expected=abcdefghijklmnop got: ponmlkjihgfedcba ${sessionKey}=sample-value`;

    expect(sanitizeInboxHealthDetail(detail)).toBe(
      `${hubSignatureKey}: [REDACTED] signature mismatch expected [REDACTED] got [REDACTED] ${sessionKey}=[REDACTED]`
    );
  });
});
