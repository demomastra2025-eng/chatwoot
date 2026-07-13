import { describe, expect, it } from 'vitest';

import {
  DEFAULT_INCOMING_CALL_RINGTONE,
  incomingCallRingtoneUrl,
  isVoiceCallRingtoneEligible,
  resolveIncomingCallRingtone,
} from './ringtone';

describe('incoming call ringtone configuration', () => {
  it('defaults to ringtone 091 for missing or unsupported values', () => {
    expect(DEFAULT_INCOMING_CALL_RINGTONE).toBe(
      'universfield-ringtone-091-496417.mp3'
    );
    expect(resolveIncomingCallRingtone()).toBe(DEFAULT_INCOMING_CALL_RINGTONE);
    expect(resolveIncomingCallRingtone('../unsafe')).toBe(
      DEFAULT_INCOMING_CALL_RINGTONE
    );
    expect(incomingCallRingtoneUrl()).toBe(
      '/audio/ringtone/universfield-ringtone-091-496417.mp3'
    );
  });

  it('keeps a supported ringtone selection', () => {
    expect(
      resolveIncomingCallRingtone('universfield-ringtone-028-380250')
    ).toBe('universfield-ringtone-028-380250.mp3');
    expect(incomingCallRingtoneUrl('universfield-ringtone-028-380250')).toBe(
      '/audio/ringtone/universfield-ringtone-028-380250.mp3'
    );
  });
});

describe('isVoiceCallRingtoneEligible', () => {
  it('accepts a pending inbound voice call', () => {
    expect(
      isVoiceCallRingtoneEligible({
        callDirection: 'inbound',
        status: 'ringing',
      })
    ).toBe(true);
  });

  it.each([
    [{ callDirection: 'outbound', status: 'ringing' }, 'outbound'],
    [{ callDirection: 'inbound', status: 'in_progress' }, 'active remotely'],
    [{ callDirection: 'inbound', isActive: true }, 'active locally'],
    [
      {
        callDirection: 'inbound',
        status: 'ringing',
        serverManagedVoiceCall: true,
      },
      'AI handled',
    ],
    [
      {
        callDirection: 'inbound',
        status: 'ringing',
        browserJoinUnsupportedReason: 'call-already-claimed',
      },
      'claimed by another operator',
    ],
    [
      {
        callDirection: 'inbound',
        status: 'ringing',
        browserJoinSupported: false,
      },
      'handled outside browser (camel case)',
    ],
    [
      {
        call_direction: 'inbound',
        status: 'ringing',
        browser_join_supported: false,
      },
      'handled outside browser (snake case)',
    ],
  ])('rejects a %s call (%s)', call => {
    expect(isVoiceCallRingtoneEligible(call)).toBe(false);
  });
});
