const filterAttribute = filter => filter?.attribute_key || filter?.attributeKey;

const filterOperator = filter =>
  filter?.filter_operator || filter?.filterOperator;

const filterQueryOperator = filter =>
  (filter?.query_operator || filter?.queryOperator || '').toLowerCase();

const filterValue = value =>
  value && typeof value === 'object' ? value.id : value;

/**
 * Returns a status that can safely be represented by the page status query.
 * Complex status expressions must remain advanced filters because a single
 * route status cannot preserve their semantics after a reload.
 */
export const extractSingleStatusFilter = (filters, allowedStatuses) => {
  if (!Array.isArray(filters) || !Array.isArray(allowedStatuses)) return null;

  const statusFilters = filters.filter(
    filter => filterAttribute(filter) === 'status'
  );
  if (statusFilters.length !== 1) return null;

  const [statusFilter] = statusFilters;
  if (filterOperator(statusFilter) !== 'equal_to') return null;
  if (filters.some(filter => filterQueryOperator(filter) === 'or')) return null;

  const values = Array.isArray(statusFilter.values) ? statusFilter.values : [];
  if (values.length !== 1) return null;

  const status = filterValue(values[0]);
  return allowedStatuses.includes(status) ? status : null;
};
