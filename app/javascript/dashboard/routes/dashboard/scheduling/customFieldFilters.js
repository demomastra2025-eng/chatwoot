import {
  buildAdvancedCustomFieldOperatorOptions,
  buildCustomFieldFilterOptions,
  buildCustomFieldFilterSummary,
  isAdvancedFilterableCustomFieldDefinition,
  isDiscreteFilterableCustomFieldDefinition,
  isFilterableCustomFieldDefinition,
  normalizeCustomFieldFilters,
  recordMatchesCustomFieldFilters,
} from 'dashboard/stores/crm/customFieldFilters';

export {
  isFilterableCustomFieldDefinition,
  isDiscreteFilterableCustomFieldDefinition,
  isAdvancedFilterableCustomFieldDefinition,
};

export const buildSchedulingCustomFieldFilterOptions = (
  definition,
  labels = {}
) => buildCustomFieldFilterOptions(definition, labels);

export const buildSchedulingAdvancedCustomFieldOperatorOptions = (
  definition,
  labels = {}
) => buildAdvancedCustomFieldOperatorOptions(definition, labels);

export const buildSchedulingCustomFieldFilterSummary = (
  definition,
  activeFilter,
  labels = {}
) => buildCustomFieldFilterSummary(definition, activeFilter, labels);

export const normalizeSchedulingCustomFieldFilters = (
  definitions = [],
  activeFilters = {},
  labels = {}
) => normalizeCustomFieldFilters(definitions, activeFilters, labels);

export const appointmentMatchesCustomFieldFilters = (
  appointment,
  definitions = [],
  activeFilters = {}
) =>
  recordMatchesCustomFieldFilters(appointment, definitions, activeFilters, {
    valueAccessor: record => record?.customAttributes,
  });
