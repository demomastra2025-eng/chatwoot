import { describe, expect, it } from 'vitest';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import {
  buildCampaignAudiencePayload,
  hasCampaignAudience,
  supportsCampaignFileAudience,
} from './campaignAudience';

describe('campaignAudience', () => {
  it('builds mutually exclusive label and file audience payloads', () => {
    expect(
      buildCampaignAudiencePayload({
        mode: 'labels',
        selectedAudience: [2, 5],
        audienceImport: { token: 'ignored' },
      })
    ).toEqual({
      audience: [
        { id: 2, type: 'Label' },
        { id: 5, type: 'Label' },
      ],
      audience_import_token: undefined,
    });

    expect(
      buildCampaignAudiencePayload({
        mode: 'file',
        selectedAudience: [2],
        audienceImport: { token: 'snapshot-token' },
      })
    ).toEqual({ audience: [], audience_import_token: 'snapshot-token' });
  });

  it('requires a completed import token for file audiences', () => {
    expect(hasCampaignAudience({ mode: 'file', audienceImport: null })).toBe(
      false
    );
    expect(
      hasCampaignAudience({
        mode: 'file',
        audienceImport: { token: 'snapshot-token' },
      })
    ).toBe(true);
    expect(hasCampaignAudience({ mode: 'labels', selectedAudience: [] })).toBe(
      false
    );
  });

  it('allows file audiences only for phone-addressable first-contact channels', () => {
    expect(supportsCampaignFileAudience(INBOX_TYPES.SMS)).toBe(true);
    expect(supportsCampaignFileAudience(INBOX_TYPES.WHATSAPP)).toBe(true);
    expect(supportsCampaignFileAudience(INBOX_TYPES.WHATSAPP_WEB)).toBe(true);
    expect(supportsCampaignFileAudience(INBOX_TYPES.TWILIO)).toBe(true);
    expect(supportsCampaignFileAudience(INBOX_TYPES.EMAIL)).toBe(false);
    expect(supportsCampaignFileAudience(INBOX_TYPES.TELEGRAM)).toBe(false);
  });
});
