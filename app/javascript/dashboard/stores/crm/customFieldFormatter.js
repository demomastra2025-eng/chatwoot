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
