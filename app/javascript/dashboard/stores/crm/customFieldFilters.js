const DISCRETE_FILTERABLE_FIELD_TYPES = ['checkbox', 'multiselect', 'select'];
const TEXT_FILTERABLE_FIELD_TYPES = ['text', 'textarea', 'url'];
const NUMERIC_FILTERABLE_FIELD_TYPES = ['number', 'currency', 'percent'];
const TEMPORAL_FILTERABLE_FIELD_TYPES = ['date', 'datetime'];
const FILTERABLE_FIELD_TYPES = [
  ...DISCRETE_FILTERABLE_FIELD_TYPES,
  ...TEXT_FILTERABLE_FIELD_TYPES,
  ...NUMERIC_FILTERABLE_FIELD_TYPES,
  ...TEMPORAL_FILTERABLE_FIELD_TYPES,
];
const VALUELESS_OPERATORS = ['is_not_present', 'is_present'];

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

const normalizeBoolean = value => {
  if (value === true || value === 'true' || value === 1 || value === '1') {
    return true;
  }

  if (value === false || value === 'false' || value === 0 || value === '0') {
    return false;
  }

  return null;
};

const normalizeTextFilterValue = value => {
  const normalized = String(value ?? '').trim();
  return normalized || null;
};

const parseDateParts = value => {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) {
    return null;
  }

  return {
    year: Number(match[1]),
    month: Number(match[2]),
    day: Number(match[3]),
  };
};

const isValidDateParts = ({ year, month, day }) => {
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return false;
  }

  const candidate = new Date(Date.UTC(year, month - 1, day));
  return (
    candidate.getUTCFullYear() === year &&
    candidate.getUTCMonth() + 1 === month &&
    candidate.getUTCDate() === day
  );
};

const normalizeNumberFilterValue = value => {
  if (value === '' || value === null || value === undefined) {
    return null;
  }

  const normalized = Number(value);
  return Number.isFinite(normalized) ? normalized : null;
};

const normalizeDateFilterValue = value => {
  const normalized = normalizeTextFilterValue(value);
  const parts = normalized ? parseDateParts(normalized) : null;
  if (!parts || !isValidDateParts(parts)) {
    return null;
  }

  return normalized;
};

const normalizeDateTimeFilterValue = value => {
  const normalized = normalizeTextFilterValue(value);
  if (!normalized) return null;

  const match =
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2})?$/.exec(
      normalized
    );
  if (!match) {
    return null;
  }

  const dateParts = {
    year: Number(match[1]),
    month: Number(match[2]),
    day: Number(match[3]),
  };
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = match[6] ? Number(match[6]) : 0;

  if (!isValidDateParts(dateParts) || hour > 23 || minute > 59 || second > 59) {
    return null;
  }

  const parsed = new Date(normalized);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
};

const formatDateTimeSummaryValue = value => {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return value;
  }

  const year = parsed.getFullYear();
  const month = String(parsed.getMonth() + 1).padStart(2, '0');
  const day = String(parsed.getDate()).padStart(2, '0');
  const hours = String(parsed.getHours()).padStart(2, '0');
  const minutes = String(parsed.getMinutes()).padStart(2, '0');

  return `${year}-${month}-${day} ${hours}:${minutes}`;
};

const normalizeArrayFilterValues = values =>
  Array.isArray(values)
    ? values.filter(value => value !== null && value !== undefined)
    : [];

const valuesMatch = (selectedValues, candidateValues) => {
  return selectedValues.some(selectedValue =>
    candidateValues.some(
      candidateValue => String(candidateValue) === String(selectedValue)
    )
  );
};

const selectedValuesForDefinition = (activeFilters, definitionKey) =>
  normalizeArrayFilterValues(activeFilters?.[definitionKey]);

const operatorKeysForDefinition = definition => {
  if (TEXT_FILTERABLE_FIELD_TYPES.includes(definition?.fieldType)) {
    return ['contains', 'equals', 'is_present', 'is_not_present'];
  }

  if (NUMERIC_FILTERABLE_FIELD_TYPES.includes(definition?.fieldType)) {
    return [
      'equals',
      'greater_than',
      'less_than',
      'is_present',
      'is_not_present',
    ];
  }

  if (TEMPORAL_FILTERABLE_FIELD_TYPES.includes(definition?.fieldType)) {
    return ['on', 'after', 'before', 'is_present', 'is_not_present'];
  }

  return [];
};

const normalizeAdvancedFilter = (definition, rawFilter) => {
  if (!rawFilter || Array.isArray(rawFilter) || typeof rawFilter !== 'object') {
    return null;
  }

  const operator = normalizeTextFilterValue(rawFilter.operator);
  const allowedOperators = operatorKeysForDefinition(definition);
  if (!allowedOperators.includes(operator)) {
    return null;
  }

  if (VALUELESS_OPERATORS.includes(operator)) {
    return { operator };
  }

  let value = null;
  if (TEXT_FILTERABLE_FIELD_TYPES.includes(definition?.fieldType)) {
    value = normalizeTextFilterValue(rawFilter.value);
  } else if (NUMERIC_FILTERABLE_FIELD_TYPES.includes(definition?.fieldType)) {
    value = normalizeNumberFilterValue(rawFilter.value);
  } else if (definition?.fieldType === 'date') {
    value = normalizeDateFilterValue(rawFilter.value);
  } else if (definition?.fieldType === 'datetime') {
    value = normalizeDateTimeFilterValue(rawFilter.value);
  }

  return value === null ? null : { operator, value };
};

const isValuePresent = value => {
  if (value === false) return true;
  if (Array.isArray(value)) {
    return value.some(
      item => item !== null && item !== undefined && item !== ''
    );
  }

  return value !== null && value !== undefined && value !== '';
};

const matchesTextFilter = (rawValue, filter) => {
  const candidateValue = normalizeTextFilterValue(rawValue);
  if (!candidateValue) return false;

  if (filter.operator === 'contains') {
    return candidateValue.toLowerCase().includes(filter.value.toLowerCase());
  }

  return candidateValue.toLowerCase() === filter.value.toLowerCase();
};

const matchesNumericFilter = (rawValue, filter) => {
  const candidateValue = normalizeNumberFilterValue(rawValue);
  if (candidateValue === null) return false;

  if (filter.operator === 'greater_than') {
    return candidateValue > filter.value;
  }

  if (filter.operator === 'less_than') {
    return candidateValue < filter.value;
  }

  return candidateValue === filter.value;
};

const matchesDateFilter = (rawValue, filter) => {
  const candidateValue = normalizeDateFilterValue(rawValue);
  if (!candidateValue) return false;

  if (filter.operator === 'after') {
    return candidateValue > filter.value;
  }

  if (filter.operator === 'before') {
    return candidateValue < filter.value;
  }

  return candidateValue === filter.value;
};

const matchesDateTimeFilter = (rawValue, filter) => {
  const candidateValue = normalizeDateTimeFilterValue(rawValue);
  if (!candidateValue) return false;

  const candidateTimestamp = new Date(candidateValue).getTime();
  const filterTimestamp = new Date(filter.value).getTime();
  if (Number.isNaN(candidateTimestamp) || Number.isNaN(filterTimestamp)) {
    return false;
  }

  if (filter.operator === 'after') {
    return candidateTimestamp > filterTimestamp;
  }

  if (filter.operator === 'before') {
    return candidateTimestamp < filterTimestamp;
  }

  return candidateTimestamp === filterTimestamp;
};

export const isFilterableCustomFieldDefinition = definition => {
  return (
    definition?.active !== false &&
    FILTERABLE_FIELD_TYPES.includes(definition?.fieldType)
  );
};

export const isDiscreteFilterableCustomFieldDefinition = definition => {
  return (
    definition?.active !== false &&
    DISCRETE_FILTERABLE_FIELD_TYPES.includes(definition?.fieldType)
  );
};

export const isAdvancedFilterableCustomFieldDefinition = definition => {
  return (
    definition?.active !== false &&
    !DISCRETE_FILTERABLE_FIELD_TYPES.includes(definition?.fieldType) &&
    FILTERABLE_FIELD_TYPES.includes(definition?.fieldType)
  );
};

export const buildCustomFieldFilterOptions = (
  definition,
  { noLabel = 'No', yesLabel = 'Yes' } = {}
) => {
  if (!isDiscreteFilterableCustomFieldDefinition(definition)) {
    return [];
  }

  if (definition.fieldType === 'checkbox') {
    return [
      {
        label: yesLabel,
        value: true,
      },
      {
        label: noLabel,
        value: false,
      },
    ];
  }

  return (definition.options || []).map(normalizeOption);
};

export const buildAdvancedCustomFieldOperatorOptions = (
  definition,
  { operators = {} } = {}
) => {
  if (!isAdvancedFilterableCustomFieldDefinition(definition)) {
    return [];
  }

  return operatorKeysForDefinition(definition).map(operator => ({
    label: operators[operator] || operator,
    value: operator,
  }));
};

export const buildCustomFieldFilterSummary = (
  definition,
  activeFilter,
  { operators = {} } = {}
) => {
  if (!isAdvancedFilterableCustomFieldDefinition(definition)) {
    return '';
  }

  const normalizedFilter = normalizeAdvancedFilter(definition, activeFilter);
  if (!normalizedFilter) {
    return '';
  }

  const operatorLabel =
    operators[normalizedFilter.operator] || normalizedFilter.operator;
  const formattedValue =
    definition?.fieldType === 'datetime'
      ? formatDateTimeSummaryValue(normalizedFilter.value)
      : normalizedFilter.value;

  return normalizedFilter.value === undefined
    ? operatorLabel
    : `${operatorLabel}: ${formattedValue}`;
};

export const normalizeCustomFieldFilters = (
  definitions = [],
  activeFilters = {},
  labels = {}
) => {
  return definitions
    .filter(isFilterableCustomFieldDefinition)
    .reduce((result, definition) => {
      if (isAdvancedFilterableCustomFieldDefinition(definition)) {
        const advancedFilter = normalizeAdvancedFilter(
          definition,
          activeFilters?.[definition.key]
        );

        if (advancedFilter) {
          result[definition.key] = advancedFilter;
        }

        return result;
      }

      const allowedOptions = buildCustomFieldFilterOptions(definition, labels);
      const selectedValues = selectedValuesForDefinition(
        activeFilters,
        definition.key
      );

      if (!selectedValues.length) {
        return result;
      }

      const allowedValues =
        definition.fieldType === 'checkbox'
          ? [true, false]
          : allowedOptions.map(option => option.value);
      const nextValues = selectedValues.filter(selectedValue =>
        valuesMatch([selectedValue], allowedValues)
      );

      if (!nextValues.length) {
        return result;
      }

      result[definition.key] = nextValues;
      return result;
    }, {});
};

export const recordMatchesCustomFieldFilters = (
  record,
  definitions = [],
  activeFilters = {},
  { valueAccessor } = {}
) => {
  const values = valueAccessor
    ? valueAccessor(record)
    : record?.customAttributes;

  return definitions
    .filter(isFilterableCustomFieldDefinition)
    .every(definition => {
      const rawValue = values?.[definition.key];

      if (isAdvancedFilterableCustomFieldDefinition(definition)) {
        const activeFilter = normalizeAdvancedFilter(
          definition,
          activeFilters?.[definition.key]
        );

        if (!activeFilter) {
          return true;
        }

        if (activeFilter.operator === 'is_present') {
          return isValuePresent(rawValue);
        }

        if (activeFilter.operator === 'is_not_present') {
          return !isValuePresent(rawValue);
        }

        if (TEXT_FILTERABLE_FIELD_TYPES.includes(definition.fieldType)) {
          return matchesTextFilter(rawValue, activeFilter);
        }

        if (NUMERIC_FILTERABLE_FIELD_TYPES.includes(definition.fieldType)) {
          return matchesNumericFilter(rawValue, activeFilter);
        }

        if (definition.fieldType === 'date') {
          return matchesDateFilter(rawValue, activeFilter);
        }

        if (definition.fieldType === 'datetime') {
          return matchesDateTimeFilter(rawValue, activeFilter);
        }

        return true;
      }

      const selectedValues = selectedValuesForDefinition(
        activeFilters,
        definition.key
      );

      if (!selectedValues.length) {
        return true;
      }

      if (definition.fieldType === 'checkbox') {
        const normalizedValue = normalizeBoolean(rawValue);
        return (
          normalizedValue !== null &&
          selectedValues.some(
            selectedValue => normalizeBoolean(selectedValue) === normalizedValue
          )
        );
      }

      if (definition.fieldType === 'multiselect') {
        const candidateValues = Array.isArray(rawValue)
          ? rawValue.filter(value => value !== null && value !== undefined)
          : [];
        return candidateValues.length
          ? valuesMatch(selectedValues, candidateValues)
          : false;
      }

      if (rawValue === null || rawValue === undefined || rawValue === '') {
        return false;
      }

      return valuesMatch(selectedValues, [rawValue]);
    });
};
