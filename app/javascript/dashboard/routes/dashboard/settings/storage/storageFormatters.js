export const BYTE_UNITS = ['B', 'KB', 'MB', 'GB', 'TB'];

// vue-i18n locales use underscores (pt_BR); Intl expects BCP 47 tags (pt-BR).
export const toIntlLocale = locale => (locale || 'en').replace(/_/g, '-');

const DATE_OPTIONS = {
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
};

const withLocaleFallback = (locale, build) => {
  try {
    return build(toIntlLocale(locale));
  } catch {
    return build('en');
  }
};

export const formatStorageBytes = (
  bytes,
  { locale, unitLabels = {}, decimals = 2 } = {}
) => {
  const value = Number(bytes) > 0 ? Number(bytes) : 0;
  const exponent =
    value > 0 ? Math.min(Math.floor(Math.log(value) / Math.log(1024)), 4) : 0;
  const unit = BYTE_UNITS[exponent];
  const amount = withLocaleFallback(locale, intlLocale =>
    new Intl.NumberFormat(intlLocale, {
      maximumFractionDigits: Math.max(decimals, 0),
    }).format(value / 1024 ** exponent)
  );
  return `${amount} ${unitLabels[unit] || unit}`;
};

export const formatStorageDate = (dateStr, locale) => {
  if (!dateStr) return '—';
  const date = new Date(dateStr);
  if (Number.isNaN(date.getTime())) return dateStr;

  return withLocaleFallback(locale, intlLocale =>
    new Intl.DateTimeFormat(intlLocale, DATE_OPTIONS).format(date)
  );
};
