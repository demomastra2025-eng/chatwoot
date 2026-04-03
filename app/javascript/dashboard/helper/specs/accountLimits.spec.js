import {
  isAccountLimitExceeded,
  normalizeAccountLimit,
} from '../accountLimits';

describe('accountLimits', () => {
  describe('#normalizeAccountLimit', () => {
    it('normalizes a snake_case summary payload', () => {
      expect(
        normalizeAccountLimit({
          consumed: 3,
          total_count: 10,
          current_available: 7,
          unlimited: false,
        })
      ).toEqual({
        consumed: 3,
        totalCount: 10,
        currentAvailable: 7,
        unlimited: false,
      });
    });

    it('normalizes a camelCase summary payload', () => {
      expect(
        normalizeAccountLimit({
          consumed: 12,
          totalCount: 20,
          currentAvailable: 8,
          unlimited: false,
        })
      ).toEqual({
        consumed: 12,
        totalCount: 20,
        currentAvailable: 8,
        unlimited: false,
      });
    });

    it('returns null for invalid values', () => {
      expect(normalizeAccountLimit(null)).toBeNull();
      expect(normalizeAccountLimit('invalid')).toBeNull();
    });
  });

  describe('#isAccountLimitExceeded', () => {
    it('returns false for unlimited limits', () => {
      expect(
        isAccountLimitExceeded({
          consumed: 500,
          total_count: 100,
          current_available: 0,
          unlimited: true,
        })
      ).toBe(false);
    });

    it('treats zero-count limits as exceeded only when consumed is positive', () => {
      expect(
        isAccountLimitExceeded({
          consumed: 1,
          total_count: 0,
          current_available: 0,
          unlimited: false,
        })
      ).toBe(true);

      expect(
        isAccountLimitExceeded({
          consumed: 0,
          total_count: 0,
          current_available: 0,
          unlimited: false,
        })
      ).toBe(false);
    });

    it('returns true when consumed reaches the total count', () => {
      expect(
        isAccountLimitExceeded({
          consumed: 10,
          total_count: 10,
          current_available: 0,
          unlimited: false,
        })
      ).toBe(true);
    });

    it('returns false when consumed stays below the total count', () => {
      expect(
        isAccountLimitExceeded({
          consumed: 4,
          total_count: 10,
          current_available: 6,
          unlimited: false,
        })
      ).toBe(false);
    });
  });
});
