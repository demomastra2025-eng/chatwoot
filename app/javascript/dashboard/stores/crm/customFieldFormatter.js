const isBlankValue = value => {
  return (
    value === '' ||
    value === null ||
    value === undefined ||
    (Array.isArray(value) && value.length === 0)
  );
};

const isTruthyCheckboxValue = value => {
  return value === true || value === 'true' || value === 1 || value === '1';
};

const normalizeOption = option => {
  if (typeof option === 'string') {
    return {
      label: option,
      value: option,
    };
  }

  return {
    label: option?.label || option?.value,
    value: option?.value,
  };
};

const resolveOptionLabel = (definition, value) => {
  const options = Array.isArray(definition?.options) ? definition.options : [];
  const resolvedOption = options
    .map(normalizeOption)
    .find(option => String(option.value) === String(value));

  return resolvedOption?.label || String(value);
};

const parseDateOnlyValue = value => {
  if (typeof value !== 'string') {
    return null;
  }

  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value.trim());
  if (!match) {
    return null;
  }

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const parsedValue = new Date(year, month - 1, day);

  if (
    Number.isNaN(parsedValue.getTime()) ||
    parsedValue.getFullYear() !== year ||
    parsedValue.getMonth() !== month - 1 ||
    parsedValue.getDate() !== day
  ) {
    return null;
  }

  return parsedValue;
};

const formatNumericValue = (value, locale) => {
  if (typeof value === 'string' && value.trim().endsWith('%')) {
    return value.trim();
  }

  const numericValue = Number(value);
  if (!Number.isFinite(numericValue)) {
    return String(value);
  }

  return new Intl.NumberFormat(locale).format(numericValue);
};

const formatDateValue = (value, locale, withTime = false) => {
  const parsedValue = withTime
    ? new Date(value)
    : parseDateOnlyValue(value) || new Date(value);
  if (Number.isNaN(parsedValue.getTime())) {
    return String(value);
  }

  return new Intl.DateTimeFormat(
    locale,
    withTime
      ? {
          day: 'numeric',
          hour: '2-digit',
          minute: '2-digit',
          month: 'short',
          year: 'numeric',
        }
      : {
          day: 'numeric',
          month: 'short',
          year: 'numeric',
        }
  ).format(parsedValue);
};

const normalizeSearchText = value =>
  String(value || '')
    .toLocaleLowerCase()
    .replace(/\u00a0/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

export const buildLocalizedNumberSearchAlias = (value, locale = 'en') => {
  const search = normalizeSearchText(value);
  if (!search || search.includes('%')) return '';

  const formatter = new Intl.NumberFormat(locale);
  const parts = formatter.formatToParts(12345.6);
  const group = parts.find(part => part.type === 'group')?.value;
  const decimal = parts.find(part => part.type === 'decimal')?.value;
  let normalized = String(value).replace(/[\s\u00a0]/g, '');
  if (group) normalized = normalized.split(group).join('');
  if (decimal) normalized = normalized.replace(decimal, '.');
  if (!/^-?\d+(?:\.\d+)?$/.test(normalized)) return '';

  const numericValue = Number(normalized);
  if (!Number.isFinite(numericValue)) return '';

  return normalizeSearchText(formatter.format(numericValue)) === search
    ? String(numericValue)
    : '';
};

export const buildLocalizedDateSearchAliases = (value, locale = 'en') => {
  const emptyAliases = { dateAlias: '', datetimeAlias: '' };
  const search = normalizeSearchText(value);
  const year = Number(search.match(/\b\d{4}\b/)?.[0]);
  if (!year) return emptyAliases;

  const month = Array.from({ length: 12 }, (_, index) => index).find(index => {
    const label = new Intl.DateTimeFormat(locale, { month: 'short' }).format(
      new Date(2000, index, 1)
    );
    return search.includes(normalizeSearchText(label));
  });
  if (month === undefined) return emptyAliases;

  const timeMatch = search.match(/\b(\d{1,2}):(\d{2})\b/);
  const numbers = search.match(/\d+/g)?.map(Number) || [];
  const resolvedDay = numbers.find(
    number => number !== year && number >= 1 && number <= 31
  );
  if (!resolvedDay) return emptyAliases;

  const parsed = new Date(year, month, resolvedDay);
  if (
    parsed.getFullYear() !== year ||
    parsed.getMonth() !== month ||
    parsed.getDate() !== resolvedDay
  ) {
    return emptyAliases;
  }

  const dateAlias = `${year}-${String(month + 1).padStart(2, '0')}-${String(resolvedDay).padStart(2, '0')}`;
  if (!timeMatch) {
    return normalizeSearchText(formatDateValue(dateAlias, locale)) === search
      ? { dateAlias, datetimeAlias: '' }
      : emptyAliases;
  }

  let hour = Number(timeMatch[1]);
  const minute = Number(timeMatch[2]);
  const dayPeriodFormatter = new Intl.DateTimeFormat(locale, {
    hour: 'numeric',
  });
  const dayPeriod = targetHour =>
    normalizeSearchText(
      dayPeriodFormatter
        .formatToParts(new Date(2000, 0, 1, targetHour))
        .find(part => part.type === 'dayPeriod')?.value
    );
  const amLabel = dayPeriod(8);
  const pmLabel = dayPeriod(20);
  const usesDayPeriod = Boolean(amLabel || pmLabel);
  if (
    minute > 59 ||
    (usesDayPeriod && (hour < 1 || hour > 12)) ||
    (!usesDayPeriod && hour > 23)
  ) {
    return emptyAliases;
  }
  if (pmLabel && search.includes(pmLabel) && hour < 12) hour += 12;
  if (amLabel && search.includes(amLabel) && hour === 12) hour = 0;

  const withTime = new Date(year, month, resolvedDay, hour, minute);
  if (normalizeSearchText(formatDateValue(withTime, locale, true)) !== search) {
    return emptyAliases;
  }

  return {
    dateAlias,
    datetimeAlias: `${withTime.toISOString().slice(0, 16)}Z`,
  };
};

const trimDisplayValue = value => {
  const normalizedValue = String(value).replace(/\s+/g, ' ').trim();

  if (normalizedValue.length <= 80) {
    return normalizedValue;
  }

  return `${normalizedValue.slice(0, 77).trimEnd()}...`;
};

export const formatCustomFieldValue = (
  definition,
  rawValue,
  { locale = 'en', yesLabel = 'Yes' } = {}
) => {
  if (isBlankValue(rawValue)) {
    return null;
  }

  switch (definition?.fieldType) {
    case 'checkbox':
      if (!isTruthyCheckboxValue(rawValue)) {
        return null;
      }

      return yesLabel;
    case 'select':
      return resolveOptionLabel(definition, rawValue);
    case 'multiselect': {
      const values = Array.isArray(rawValue) ? rawValue : [rawValue];
      const labels = values
        .filter(value => !isBlankValue(value))
        .map(value => resolveOptionLabel(definition, value));

      if (!labels.length) {
        return null;
      }

      return trimDisplayValue(labels.join(', '));
    }
    case 'date':
      return formatDateValue(rawValue, locale, false);
    case 'datetime':
      return formatDateValue(rawValue, locale, true);
    case 'percent': {
      const formattedValue = formatNumericValue(rawValue, locale);
      if (
        formattedValue === String(rawValue).trim() &&
        formattedValue.endsWith('%')
      ) {
        return formattedValue;
      }

      return `${formattedValue}%`;
    }
    case 'currency':
    case 'number':
      return formatNumericValue(rawValue, locale);
    default:
      return trimDisplayValue(rawValue);
  }
};

export const resolveCustomFieldEntries = (
  definitions = [],
  values = {},
  options = {}
) => {
  return definitions
    .filter(definition => definition?.active !== false)
    .map(definition => {
      const rawValue = values?.[definition.key];
      const displayValue = formatCustomFieldValue(
        definition,
        rawValue,
        options
      );

      if (!displayValue) {
        return null;
      }

      return {
        displayValue,
        key: definition.key,
        label: definition.label || definition.key,
      };
    })
    .filter(Boolean);
};

export const buildCustomFieldSummary = (
  definitions = [],
  values = {},
  { maxItems = Infinity, ...options } = {}
) => {
  return resolveCustomFieldEntries(definitions, values, options).slice(
    0,
    maxItems
  );
};
