import { INBOX_TYPES, getInboxIconByType } from 'dashboard/helper/inbox';

const PROVIDER_CHANNEL_TYPE_MAP = {
  api: INBOX_TYPES.API,
  email: INBOX_TYPES.EMAIL,
  facebook_page: INBOX_TYPES.FB,
  instagram: INBOX_TYPES.INSTAGRAM,
  line: INBOX_TYPES.LINE,
  linkedin_personal: INBOX_TYPES.LINKEDIN_PERSONAL,
  telegram: INBOX_TYPES.TELEGRAM,
  telegram_personal: INBOX_TYPES.TELEGRAM_PERSONAL,
  tiktok: INBOX_TYPES.TIKTOK,
  vk_community: INBOX_TYPES.VK,
  voice: INBOX_TYPES.VOICE,
  web_widget: INBOX_TYPES.WEB,
  whatsapp: INBOX_TYPES.WHATSAPP,
  whatsapp_web: INBOX_TYPES.WHATSAPP_WEB,
};

export const sourceValue = (source, camelKey, snakeKey = null) => {
  if (!source) {
    return undefined;
  }

  const resolvedSnakeKey =
    snakeKey ||
    camelKey.replace(/[A-Z]/g, letter => `_${letter.toLowerCase()}`);

  return source[camelKey] ?? source[resolvedSnakeKey];
};

const humanizeSourceName = value => {
  const rawValue = value?.replace('Channel::', '') || '';
  if (!rawValue) {
    return '';
  }

  return rawValue
    .replace(/_/g, ' ')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .split(' ')
    .filter(Boolean)
    .map(chunk => chunk.charAt(0).toUpperCase() + chunk.slice(1))
    .join(' ');
};

export const displayContactSourceLabel = (source, t) => {
  const kind = sourceValue(source, 'kind');

  if (kind === 'manual') {
    return t('CONTACT_PANEL.SOURCE_IDENTITIES.MANUAL_NAME');
  }

  if (kind === 'contact_avatar') {
    return t('CONTACT_PANEL.SOURCE_IDENTITIES.CONTACT_PHOTO');
  }

  const provider =
    sourceValue(source, 'provider') || sourceValue(source, 'channelType');

  return (
    humanizeSourceName(provider) || t('CONTACT_PANEL.SOURCE_IDENTITIES.UNKNOWN')
  );
};

export const getContactSourceIconClass = source => {
  const kind = sourceValue(source, 'kind');

  if (kind === 'manual') {
    return 'i-lucide-user-round-pen';
  }

  if (kind === 'contact_avatar') {
    return 'i-lucide-image';
  }

  const provider = sourceValue(source, 'provider');
  const channelType =
    sourceValue(source, 'channelType') || PROVIDER_CHANNEL_TYPE_MAP[provider];

  return getInboxIconByType(channelType, sourceValue(source, 'medium'), 'fill');
};

const HIDDEN_CHANNEL_IDENTITY_PATTERN =
  /^(?:[a-z_]+:)?[^@\s]+@(?:lid|s\.whatsapp\.net)$/i;

export const displayableIdentityDetail = (...values) => {
  return (
    values
      .map(value => String(value || '').trim())
      .find(value => value && !HIDDEN_CHANNEL_IDENTITY_PATTERN.test(value)) ||
    ''
  );
};
