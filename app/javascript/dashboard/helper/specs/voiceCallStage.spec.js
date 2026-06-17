import { describe, expect, it } from 'vitest';

import {
  getOutboundCallStage,
  OUTBOUND_CALL_STAGE_LABEL_KEYS,
} from '../voiceCallStage';

describe('voice call stage helper', () => {
  it('does not expose a stage for non-outbound calls', () => {
    expect(getOutboundCallStage({ callDirection: 'inbound' })).toEqual({
      labelKey: '',
      showDuration: false,
    });
  });

  it('shows the operator connection stage before native customer-leg evidence', () => {
    expect(
      getOutboundCallStage({ callDirection: 'outbound', status: 'created' })
    ).toEqual({
      labelKey: OUTBOUND_CALL_STAGE_LABEL_KEYS.CONNECTING_OPERATOR,
      showDuration: false,
    });
  });

  it('shows customer dialing after the operator leg answers', () => {
    expect(
      getOutboundCallStage({
        callDirection: 'outbound',
        callEvent: 'operator_answered',
      })
    ).toEqual({
      labelKey: OUTBOUND_CALL_STAGE_LABEL_KEYS.CALLING_CUSTOMER,
      showDuration: false,
    });
  });

  it('shows customer ringing for callee dial status events', () => {
    expect(
      getOutboundCallStage({
        callDirection: 'outbound',
        callEvent: 'dial-status',
        callLeg: 'callee',
        rawStatus: 'RINGING',
      })
    ).toEqual({
      labelKey: OUTBOUND_CALL_STAGE_LABEL_KEYS.CUSTOMER_RINGING,
      showDuration: false,
    });
  });

  it('shows active duration once the customer leg answers', () => {
    expect(
      getOutboundCallStage({
        callDirection: 'outbound',
        callEvent: 'dial_status',
        callLeg: 'customer',
        rawStatus: 'UP',
      })
    ).toEqual({
      labelKey: OUTBOUND_CALL_STAGE_LABEL_KEYS.IN_PROGRESS,
      showDuration: true,
    });
  });

  it('does not let stale customer ringing metadata override an in-progress customer leg', () => {
    expect(
      getOutboundCallStage({
        callDirection: 'outbound',
        status: 'in_progress',
        callEvent: 'dial_status',
        callLeg: 'callee',
        rawStatus: 'RINGING',
      })
    ).toEqual({
      labelKey: OUTBOUND_CALL_STAGE_LABEL_KEYS.IN_PROGRESS,
      showDuration: true,
    });
  });

  it('falls back to active duration when backend only reports in_progress', () => {
    expect(
      getOutboundCallStage({
        callDirection: 'outbound',
        status: 'in_progress',
      })
    ).toEqual({
      labelKey: OUTBOUND_CALL_STAGE_LABEL_KEYS.IN_PROGRESS,
      showDuration: true,
    });
  });
});
