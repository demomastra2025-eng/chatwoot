import {
  companyMatchesSearch,
  normalizeCompanySearch,
  resolveCompaniesPageAfterDelete,
} from './helpers';

describe('companies helpers', () => {
  describe('#normalizeCompanySearch', () => {
    it('normalizes empty values', () => {
      expect(normalizeCompanySearch()).toBe('');
      expect(normalizeCompanySearch(null)).toBe('');
    });

    it('trims and lowercases the search string', () => {
      expect(normalizeCompanySearch('  AcMe.COM  ')).toBe('acme.com');
    });
  });

  describe('#companyMatchesSearch', () => {
    const company = {
      name: 'Acme Clinic',
      domain: 'acme.com',
    };

    it('matches empty search values', () => {
      expect(companyMatchesSearch(company, '')).toBe(true);
    });

    it('matches by company name', () => {
      expect(companyMatchesSearch(company, 'clinic')).toBe(true);
    });

    it('matches by company domain', () => {
      expect(companyMatchesSearch(company, 'ACME.COM')).toBe(true);
    });

    it('returns false when company does not match the search', () => {
      expect(companyMatchesSearch(company, 'globex')).toBe(false);
    });
  });

  describe('#resolveCompaniesPageAfterDelete', () => {
    it('keeps the current page when there are still items on the page', () => {
      expect(
        resolveCompaniesPageAfterDelete({
          currentPage: 2,
          remainingItemsOnPage: 3,
        })
      ).toBe(2);
    });

    it('moves back one page after deleting the last item on a later page', () => {
      expect(
        resolveCompaniesPageAfterDelete({
          currentPage: 3,
          remainingItemsOnPage: 0,
        })
      ).toBe(2);
    });

    it('stays on the first page when it becomes empty', () => {
      expect(
        resolveCompaniesPageAfterDelete({
          currentPage: 1,
          remainingItemsOnPage: 0,
        })
      ).toBe(1);
    });
  });
});
