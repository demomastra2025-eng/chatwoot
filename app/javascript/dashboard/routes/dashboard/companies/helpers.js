export const normalizeCompanySearch = value =>
  String(value || '')
    .trim()
    .toLowerCase();

export const companyMatchesSearch = (company = {}, search = '') => {
  const normalizedSearch = normalizeCompanySearch(search);

  if (!normalizedSearch) {
    return true;
  }

  return [company.name, company.domain].some(value =>
    normalizeCompanySearch(value).includes(normalizedSearch)
  );
};

export const resolveCompaniesPageAfterDelete = ({
  currentPage = 1,
  remainingItemsOnPage = 0,
} = {}) => {
  if (remainingItemsOnPage === 0 && currentPage > 1) {
    return currentPage - 1;
  }

  return currentPage;
};
