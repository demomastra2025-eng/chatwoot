import { describe, expect, it } from 'vitest';

import {
  isManualPromotionEnabled,
  sharedPhoneErrorReason,
  visibleSharedPhoneHint,
} from './sharedPhoneState';

describe('sharedPhoneState', () => {
  const hint = { masked_phone: '+7 *** ***-**-09', reason: 'released' };

  it('hides the hint while manual promotion is switched off', () => {
    expect(visibleSharedPhoneHint({ hint })).toBeNull();
    expect(
      visibleSharedPhoneHint({ manual_promotion_enabled: false, hint })
    ).toBeNull();
    expect(isManualPromotionEnabled({ hint })).toBe(false);
    expect(isManualPromotionEnabled(null)).toBe(false);
  });

  it('shows the hint only when the server reports the switch on', () => {
    expect(
      visibleSharedPhoneHint({ manual_promotion_enabled: true, hint })
    ).toEqual(hint);
    expect(
      visibleSharedPhoneHint({ manual_promotion_enabled: true, hint: null })
    ).toBeNull();
    expect(isManualPromotionEnabled({ manual_promotion_enabled: true })).toBe(
      true
    );
  });

  it('maps the disabled answers of the promote API to one reason', () => {
    expect(sharedPhoneErrorReason('SHARED_PHONE_PROMOTION_DISABLED')).toBe(
      'disabled'
    );
    expect(
      sharedPhoneErrorReason('SHARED_PHONE_HISTORY_TRANSFER_DISABLED')
    ).toBe('disabled');
    expect(sharedPhoneErrorReason('SHARED_PHONE_TAKEN')).toBe('taken');
    expect(sharedPhoneErrorReason('SHARED_PHONE_STATE_CHANGED')).toBe(
      'state_changed'
    );
    expect(sharedPhoneErrorReason(undefined)).toBe('failed');
  });
});
