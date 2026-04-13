import { format, isSameYear, differenceInDays } from 'date-fns';

const DEFAULT_LOCALE = 'en';
const DEFAULT_TIME_PATTERN = 'HH:mm';
const DEFAULT_DATE_PATTERN = 'MMM d, yyyy';
const DEFAULT_DATE_TIME_PATTERN = 'LLL d yyyy, HH:mm';
const SHORT_RELATIVE_TIME_FORMATS = Object.freeze({
  en: {
    futurePrefix: 'in ',
    now: 'now',
    pastSuffix: ' ago',
    separator: '',
    units: {
      day: 'd',
      hour: 'h',
      minute: 'm',
      month: 'mo',
      year: 'y',
    },
  },
  kk: {
    futureSuffix: ' кейін',
    now: 'қазір',
    pastSuffix: ' бұрын',
    separator: ' ',
    units: {
      day: 'күн',
      hour: 'сағ',
      minute: 'мин',
      month: 'ай',
      year: 'ж',
    },
  },
  ru: {
    futurePrefix: 'через ',
    now: 'сейчас',
    pastSuffix: ' назад',
    separator: ' ',
    units: {
      day: 'д',
      hour: 'ч',
      minute: 'мин',
      month: 'мес',
      year: 'г',
    },
  },
});

const normalizeLocale = locale =>
  String(locale || DEFAULT_LOCALE).replace(/_/g, '-');

const resolveLocale = () => {
  const preferredLocale =
    (typeof document !== 'undefined' && document.documentElement?.lang) ||
    (typeof window !== 'undefined' && window.chatwootConfig?.selectedLocale) ||
    (typeof navigator !== 'undefined' && navigator.language) ||
    DEFAULT_LOCALE;

  const normalizedLocale = normalizeLocale(preferredLocale);
  if (Intl.DateTimeFormat.supportedLocalesOf([normalizedLocale]).length) {
    return normalizedLocale;
  }

  const baseLocale = normalizedLocale.split('-')[0];
  if (Intl.DateTimeFormat.supportedLocalesOf([baseLocale]).length) {
    return baseLocale;
  }

  return DEFAULT_LOCALE;
};

const resolveShortRelativeTimeFormat = () => {
  const locale = resolveLocale().split('-')[0];
  return SHORT_RELATIVE_TIME_FORMATS[locale] || SHORT_RELATIVE_TIME_FORMATS.en;
};

const coerceToDate = value => {
  if (value instanceof Date) {
    return new Date(value.getTime());
  }

  if (typeof value === 'number') {
    return new Date(value > 1e12 ? value : value * 1000);
  }

  if (typeof value === 'string') {
    const trimmedValue = value.trim();
    if (/^\d+$/.test(trimmedValue)) {
      const numericValue = Number(trimmedValue);
      return new Date(numericValue > 1e12 ? numericValue : numericValue * 1000);
    }

    return new Date(trimmedValue);
  }

  return new Date(value);
};

const isValidDate = date => !Number.isNaN(date.getTime());

const normalizeLegacyPattern = pattern =>
  String(pattern || '')
    .replace(/\s*a+\b/gi, '')
    .replace(/hh/g, 'HH')
    .replace(/\bh\b/g, 'H')
    .trim();

const resolveDateTimeOptions = pattern => {
  const normalizedPattern = normalizeLegacyPattern(pattern);
  const options = {};
  const hasTime =
    /:/.test(normalizedPattern) ||
    /\b[Hh]{1,2}\b/.test(normalizedPattern) ||
    /\bp\b/.test(normalizedPattern);

  if (/MMMM|LLLL/.test(normalizedPattern)) {
    options.month = 'long';
  } else if (/MMM|LLL/.test(normalizedPattern)) {
    options.month = 'short';
  } else if (/MM/.test(normalizedPattern)) {
    options.month = '2-digit';
  } else if (/\bM\b/.test(normalizedPattern)) {
    options.month = 'numeric';
  }

  if (/\bdd\b/.test(normalizedPattern)) {
    options.day = '2-digit';
  } else if (/\bd\b/.test(normalizedPattern)) {
    options.day = 'numeric';
  }

  if (/yyyy|yyy|\by\b/.test(normalizedPattern)) {
    options.year = 'numeric';
  } else if (/yy/.test(normalizedPattern)) {
    options.year = '2-digit';
  }

  if (hasTime) {
    options.hour = /HH/.test(normalizedPattern) ? '2-digit' : 'numeric';
    options.minute = '2-digit';
    options.hour12 = false;
  }

  return Object.keys(options).length ? options : null;
};

const formatWithIntl = (value, pattern) => {
  const date = coerceToDate(value);
  if (!isValidDate(date)) return '';

  const options = resolveDateTimeOptions(pattern);
  if (!options) return '';

  try {
    return new Intl.DateTimeFormat(resolveLocale(), options).format(date);
  } catch {
    return '';
  }
};

const formatWithFallback = (value, pattern) => {
  const date = coerceToDate(value);
  if (!isValidDate(date)) return '';

  try {
    return format(date, normalizeLegacyPattern(pattern));
  } catch {
    return '';
  }
};

const formatLocalizedDateTime = (value, pattern) => {
  const formattedValue =
    formatWithIntl(value, pattern) || formatWithFallback(value, pattern);

  return String(formattedValue).replace(/,\s(?=\d{1,2}:\d{2}\b)/g, ' ');
};

const getRelativeUnit = diffInSeconds => {
  const absoluteSeconds = Math.abs(diffInSeconds);

  if (absoluteSeconds < 45) {
    return ['second', Math.round(diffInSeconds)];
  }
  if (absoluteSeconds < 45 * 60) {
    return ['minute', Math.round(diffInSeconds / 60)];
  }
  if (absoluteSeconds < 22 * 60 * 60) {
    return ['hour', Math.round(diffInSeconds / 3600)];
  }
  if (absoluteSeconds < 26 * 24 * 60 * 60) {
    return ['day', Math.round(diffInSeconds / 86400)];
  }
  if (absoluteSeconds < 11 * 30 * 24 * 60 * 60) {
    return ['month', Math.round(diffInSeconds / (30 * 24 * 60 * 60))];
  }

  return ['year', Math.round(diffInSeconds / (365 * 24 * 60 * 60))];
};

const formatCompactRelativeValue = (unit, value, direction, withAgo) => {
  const formatConfig = resolveShortRelativeTimeFormat();

  if (unit === 'second' || !value) {
    return formatConfig.now;
  }

  const unitLabel = formatConfig.units[unit];
  if (!unitLabel) {
    return null;
  }

  const compact = `${Math.abs(value)}${formatConfig.separator}${unitLabel}`;
  if (!withAgo) {
    return compact;
  }

  if (direction > 0) {
    return `${formatConfig.futurePrefix || ''}${compact}${
      formatConfig.futureSuffix || ''
    }`;
  }

  return `${formatConfig.pastPrefix || ''}${compact}${
    formatConfig.pastSuffix || ''
  }`;
};

const parseLegacyRelativeTime = value => {
  const normalizedValue = String(value || '')
    .toLowerCase()
    .replace(/\b(about|over|almost)\b/g, '')
    .replace(/\s+/g, ' ')
    .trim();

  if (
    normalizedValue === 'less than a minute ago' ||
    normalizedValue === 'in less than a minute'
  ) {
    return {
      direction: 0,
      unit: 'second',
      value: 0,
    };
  }

  const matchedValue = normalizedValue.match(
    /^(?:(in)\s+)?(a|an|\d+)\s+(minute|minutes|hour|hours|day|days|month|months|year|years)(?:\s+(ago))?$/
  );

  if (!matchedValue) {
    return null;
  }

  const [, futureMarker, countToken, rawUnit] = matchedValue;
  const unitMap = {
    day: 'day',
    days: 'day',
    hour: 'hour',
    hours: 'hour',
    minute: 'minute',
    minutes: 'minute',
    month: 'month',
    months: 'month',
    year: 'year',
    years: 'year',
  };

  return {
    direction: futureMarker ? 1 : -1,
    unit: unitMap[rawUnit],
    value: ['a', 'an'].includes(countToken) ? 1 : Number(countToken),
  };
};

const compactRelativeTime = (value, withAgo = false) => {
  const date = coerceToDate(value);
  if (!isValidDate(date)) return null;

  const diffInSeconds = Math.round((date.getTime() - Date.now()) / 1000);
  const [unit, relativeValue] = getRelativeUnit(diffInSeconds);
  return formatCompactRelativeValue(
    unit,
    relativeValue,
    Math.sign(diffInSeconds),
    withAgo
  );
};

/**
 * Formats a timestamp into a human-readable time format in 24-hour time.
 * @param {number|string|Date} time - Unix timestamp, ISO string, or Date.
 * @param {string} [dateFormat='HH:mm'] - Desired format of the time.
 * @returns {string} Formatted time string.
 */
export const messageStamp = (time, dateFormat = DEFAULT_TIME_PATTERN) => {
  return formatLocalizedDateTime(time, dateFormat);
};

/**
 * Provides a formatted timestamp, adjusting the format based on the current year.
 * @param {number|string|Date} time - Unix timestamp, ISO string, or Date.
 * @param {string} [dateFormat='MMM d, yyyy'] - Desired date format.
 * @returns {string} Formatted date string.
 */
export const messageTimestamp = (time, dateFormat = DEFAULT_DATE_PATTERN) => {
  const messageTime = coerceToDate(time);
  if (!isValidDate(messageTime)) return '';

  if (!isSameYear(messageTime, new Date())) {
    return formatLocalizedDateTime(messageTime, DEFAULT_DATE_TIME_PATTERN);
  }

  return formatLocalizedDateTime(messageTime, dateFormat);
};

/**
 * Converts a timestamp to a locale-aware relative time string.
 * @param {number|string|Date} time - Unix timestamp, ISO string, or Date.
 * @returns {string} Relative time string.
 */
export const dynamicTime = time => {
  const unixTime = coerceToDate(time);
  if (!isValidDate(unixTime)) return '';

  const diffInSeconds = Math.round((unixTime.getTime() - Date.now()) / 1000);
  const [unit, value] = getRelativeUnit(diffInSeconds);

  try {
    return new Intl.RelativeTimeFormat(resolveLocale(), {
      numeric: 'auto',
    }).format(value, unit);
  } catch {
    return formatWithFallback(unixTime, DEFAULT_DATE_TIME_PATTERN);
  }
};

/**
 * Formats a timestamp into a specified date format.
 * @param {number|string|Date} time - Unix timestamp, ISO string, or Date.
 * @param {string} [dateFormat='MMM d, yyyy'] - Desired date format.
 * @returns {string} Formatted date string.
 */
export const dateFormat = (time, df = DEFAULT_DATE_PATTERN) => {
  return formatLocalizedDateTime(time, df);
};

/**
 * Converts relative time into a compact form. Supports timestamps directly,
 * and falls back to legacy English string parsing for older call sites.
 * @param {number|string|Date} time - Timestamp/Date or a legacy relative string.
 * @param {boolean} [withAgo=false] - Whether to append direction text.
 * @returns {string} Compact relative time string.
 */
export const shortTimestamp = (time, withAgo = false) => {
  const compactTime = compactRelativeTime(time, withAgo);
  if (compactTime) {
    return compactTime;
  }

  const parsedLegacyTime = parseLegacyRelativeTime(time);
  if (parsedLegacyTime) {
    return formatCompactRelativeValue(
      parsedLegacyTime.unit,
      parsedLegacyTime.value,
      parsedLegacyTime.direction,
      withAgo
    );
  }

  return String(time);
};

/**
 * Calculates the difference in days between now and a given timestamp.
 * @param {Date} now - Current date/time.
 * @param {number} timestampInSeconds - Unix timestamp in seconds.
 * @returns {number} Number of days difference.
 */
export const getDayDifferenceFromNow = (now, timestampInSeconds) => {
  const date = new Date(timestampInSeconds * 1000);
  return differenceInDays(now, date);
};

/**
 * Checks if more than 24 hours have passed since a given timestamp.
 * Useful for determining if retry/refresh actions should be disabled.
 * @param {number} timestamp - Unix timestamp.
 * @returns {boolean} True if more than 24 hours have passed.
 */
export const hasOneDayPassed = timestamp => {
  if (!timestamp) return true;
  return getDayDifferenceFromNow(new Date(), timestamp) >= 1;
};
