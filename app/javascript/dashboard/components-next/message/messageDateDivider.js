const MILLISECONDS_IN_DAY = 24 * 60 * 60 * 1000;
const DEFAULT_LOCALE = 'en';

const normalizeLocale = locale => {
  const rawLocale = locale?.value ?? locale;
  return String(rawLocale || DEFAULT_LOCALE).replace(/_/g, '-');
};

const parseMessageDate = value => {
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

const isValidDate = date =>
  date instanceof Date && !Number.isNaN(date.getTime());

const startOfLocalDay = date =>
  new Date(date.getFullYear(), date.getMonth(), date.getDate());

const capitalizeLabel = value => {
  const normalizedValue = String(value || '');
  return (
    normalizedValue.charAt(0).toLocaleUpperCase() + normalizedValue.slice(1)
  );
};

export const messageDateKey = value => {
  const date = parseMessageDate(value);
  if (!isValidDate(date)) return '';

  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
};

const formatWithIntl = (date, locale, options) => {
  try {
    return new Intl.DateTimeFormat(locale, options).format(date);
  } catch {
    return new Intl.DateTimeFormat(DEFAULT_LOCALE, options).format(date);
  }
};

export const formatMessageDateDivider = (
  value,
  { t, locale, now = new Date() } = {}
) => {
  const date = parseMessageDate(value);
  const today = parseMessageDate(now);
  if (!isValidDate(date) || !isValidDate(today)) return '';

  const normalizedLocale = normalizeLocale(locale);
  const dayDifference = Math.round(
    (startOfLocalDay(today) - startOfLocalDay(date)) / MILLISECONDS_IN_DAY
  );

  if (dayDifference === 0) {
    return t?.('CONVERSATION.DATE_DIVIDER.TODAY') || 'Today';
  }
  if (dayDifference === 1) {
    return t?.('CONVERSATION.DATE_DIVIDER.YESTERDAY') || 'Yesterday';
  }

  if (dayDifference > 1 && dayDifference < 7) {
    return capitalizeLabel(
      formatWithIntl(date, normalizedLocale, { weekday: 'long' })
    );
  }

  const isSameYear = date.getFullYear() === today.getFullYear();
  return formatWithIntl(date, normalizedLocale, {
    day: 'numeric',
    month: 'short',
    ...(isSameYear ? {} : { year: 'numeric' }),
  });
};
