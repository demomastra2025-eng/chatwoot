import { getIntlLocale } from './intlLocale';

const DAY_MS = 24 * 60 * 60 * 1000;

// The WhatsApp token is about to expire when the server marks it `expiring`.
// The payload carries `expires_at` (ISO date) and `expires_in_days`, counted
// when the token was last checked, so the days are recounted from the date.
export const getWhatsappTokenExpiry = (inbox, now = new Date()) => {
  const tokenHealth = inbox?.provider_config?.token_health;
  if (tokenHealth?.status !== 'expiring') {
    return null;
  }

  const parsedDate = tokenHealth.expires_at
    ? new Date(tokenHealth.expires_at)
    : null;
  const expiresAt =
    parsedDate && !Number.isNaN(parsedDate.getTime()) ? parsedDate : null;
  const reportedDays = Number(tokenHealth.expires_in_days);

  let daysLeft = null;
  if (expiresAt) {
    daysLeft = Math.floor((expiresAt.getTime() - now.getTime()) / DAY_MS);
  } else if (
    tokenHealth.expires_in_days !== null &&
    tokenHealth.expires_in_days !== undefined &&
    Number.isFinite(reportedDays)
  ) {
    daysLeft = Math.floor(reportedDays);
  }

  return {
    expiresAt,
    daysLeft: daysLeft === null ? null : Math.max(daysLeft, 0),
  };
};

const formatExpiryDate = (date, intlLocale, now) => {
  const options = { day: 'numeric', month: 'long' };
  if (date.getFullYear() !== now.getFullYear()) {
    options.year = 'numeric';
  }

  try {
    return new Intl.DateTimeFormat(intlLocale, options).format(date);
  } catch {
    return date.toISOString().slice(0, 10);
  }
};

// «Авторизация WhatsApp истекает через 9 дн. (1 ноября). Переподключите
// заранее.» Empty when the payload does not say when the token expires.
export const describeWhatsappTokenExpiry = (
  expiry,
  { t, locale, now = new Date() }
) => {
  if (!expiry || expiry.daysLeft === null) {
    return '';
  }

  if (expiry.daysLeft === 0) {
    return t('INBOX_MGMT.HEALTH_STATUS.TOKEN_EXPIRING_TODAY');
  }

  const date = expiry.expiresAt
    ? formatExpiryDate(expiry.expiresAt, getIntlLocale(locale), now)
    : '';

  if (!date) {
    return t('INBOX_MGMT.HEALTH_STATUS.TOKEN_EXPIRING_IN_DAYS_NO_DATE', {
      days: expiry.daysLeft,
    });
  }

  return t('INBOX_MGMT.HEALTH_STATUS.TOKEN_EXPIRING_IN_DAYS', {
    days: expiry.daysLeft,
    date,
  });
};
