import { INBOX_TYPES } from 'dashboard/helper/inbox';

// One useful line under the channel name in the channels list (phone number,
// bot username, site domain, ...). Only data the list already has is used.

const VOICE_PROVIDER_LABEL_KEYS = {
  twilio: 'TWILIO',
  sipuni: 'SIPUNI',
  binotel: 'BINOTEL',
  beeline: 'BEELINE',
  asterisk: 'ASTERISK_ANALOG',
  asterisk_analog: 'ASTERISK_ANALOG',
  wazo: 'WAZO',
};

const WAZO_CARRIER_LABEL_KEYS = {
  altel: 'ALTEL',
  tele2: 'TELE2',
  kazakhtelecom: 'KAZAKHTELECOM',
  kcell: 'KCELL',
  beeline_trunk: 'BEELINE',
  custom: 'WAZO',
};

const PROVIDER_LABEL_KEY_PREFIX = 'INBOX_MGMT.ADD.VOICE.PROVIDERS';

const normalizeValue = value => (value ? String(value).trim() : '');

const pickFirstValue = values => values.map(normalizeValue).find(Boolean) || '';

const humanize = value =>
  normalizeValue(value)
    .replaceAll('_', ' ')
    .split(' ')
    .filter(Boolean)
    .map(word => `${word.charAt(0).toUpperCase()}${word.slice(1)}`)
    .join(' ');

const getPhone = inbox => {
  const phone = pickFirstValue([
    inbox.phone_number,
    inbox.display_phone_number,
    inbox.telephony?.phone_number,
    inbox.additional_attributes?.evolution?.number,
  ]).replace(/^whatsapp:/i, '');

  return /^\d{7,15}$/.test(phone) ? `+${phone}` : phone;
};

const getDomain = value => {
  const rawValue = normalizeValue(value);
  if (!rawValue) return '';

  try {
    const hasScheme = /^[a-z][a-z\d+.-]*:\/\//i.test(rawValue);
    const { hostname } = new URL(hasScheme ? rawValue : `https://${rawValue}`);
    return hostname.replace(/^www\./, '');
  } catch {
    return rawValue.replace(/^https?:\/\//, '').split(/[/?#]/)[0];
  }
};

const getVoiceProviderName = (inbox, t) => {
  const provider = pickFirstValue([
    inbox.provider,
    inbox.telephony?.provider,
  ]).toLowerCase();

  if (!provider) return '';

  if (provider === 'wazo') {
    const carrier = pickFirstValue([
      inbox.provider_config?.carrier_kind,
      inbox.telephony?.carrier_kind,
    ]).toLowerCase();

    if (carrier && !WAZO_CARRIER_LABEL_KEYS[carrier]) {
      return humanize(carrier);
    }
    return t(
      `${PROVIDER_LABEL_KEY_PREFIX}.${WAZO_CARRIER_LABEL_KEYS[carrier] || 'WAZO'}`
    );
  }

  const labelKey = VOICE_PROVIDER_LABEL_KEYS[provider];
  return labelKey
    ? t(`${PROVIDER_LABEL_KEY_PREFIX}.${labelKey}`)
    : humanize(provider);
};

const withHandlePrefix = value => {
  const handle = normalizeValue(value).replace(/^@/, '');
  return handle ? `@${handle}` : '';
};

const getInstagramHandle = inbox => {
  // The inbox is named after the Instagram account when it is connected.
  const name = normalizeValue(inbox.name);
  return /^@?[\w.]{1,30}$/.test(name) ? withHandlePrefix(name) : '';
};

const getSubtitleText = (inbox, t) => {
  switch (inbox.channel_type) {
    case INBOX_TYPES.WHATSAPP:
    case INBOX_TYPES.WHATSAPP_WEB:
    case INBOX_TYPES.TWILIO:
    case INBOX_TYPES.SMS:
    case INBOX_TYPES.TELEGRAM_PERSONAL:
      return { icon: 'i-lucide-phone', text: getPhone(inbox) };
    case INBOX_TYPES.VOICE:
      return {
        icon: 'i-lucide-phone',
        text: [getPhone(inbox), getVoiceProviderName(inbox, t)]
          .filter(Boolean)
          .join(' · '),
      };
    case INBOX_TYPES.TELEGRAM:
      return { icon: 'i-lucide-bot', text: withHandlePrefix(inbox.bot_name) };
    case INBOX_TYPES.WEB:
      return { icon: 'i-lucide-globe', text: getDomain(inbox.website_url) };
    case INBOX_TYPES.EMAIL:
      return { icon: 'i-lucide-mail', text: normalizeValue(inbox.email) };
    case INBOX_TYPES.INSTAGRAM:
      return { icon: 'i-lucide-at-sign', text: getInstagramHandle(inbox) };
    case INBOX_TYPES.WEIXIN:
      return {
        icon: 'i-lucide-user-round',
        text: normalizeValue(inbox.display_name),
      };
    case INBOX_TYPES.VK:
      return {
        icon: 'i-lucide-link',
        text: inbox.group_id ? `vk.com/club${inbox.group_id}` : '',
      };
    default:
      return null;
  }
};

export const getInboxListSubtitle = (inbox, t) => {
  if (!inbox) return null;

  const subtitle = getSubtitleText(inbox, t);
  return subtitle?.text ? subtitle : null;
};
