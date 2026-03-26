import { companyMatchesSearch, normalizeCompanySearch } from './helpers';

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
});
