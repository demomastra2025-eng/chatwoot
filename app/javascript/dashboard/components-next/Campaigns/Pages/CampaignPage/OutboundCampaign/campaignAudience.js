import { INBOX_TYPES } from 'dashboard/helper/inbox';

const FILE_AUDIENCE_CHANNEL_TYPES = [
  INBOX_TYPES.SMS,
  INBOX_TYPES.TWILIO,
  INBOX_TYPES.WHATSAPP,
  INBOX_TYPES.WHATSAPP_WEB,
];

export const supportsCampaignFileAudience = channelType =>
  FILE_AUDIENCE_CHANNEL_TYPES.includes(channelType);

export const buildCampaignAudiencePayload = ({
  mode,
  selectedAudience = [],
  audienceImport,
}) => ({
  audience:
    mode === 'labels'
      ? selectedAudience.map(id => ({ id, type: 'Label' }))
      : [],
  audience_import_token: mode === 'file' ? audienceImport?.token : undefined,
});

export const hasCampaignAudience = ({
  mode,
  selectedAudience = [],
  audienceImport,
}) =>
  mode === 'file'
    ? Boolean(audienceImport?.token)
    : selectedAudience.length > 0;
