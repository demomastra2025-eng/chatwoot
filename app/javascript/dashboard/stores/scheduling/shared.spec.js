import { describe, expect, it } from 'vitest';

import { toIntegerNumeric } from './shared';

describe('scheduling shared helpers', () => {
  describe('toIntegerNumeric', () => {
    it('accepts integer values and decimal zero values', () => {
      expect(toIntegerNumeric(1000, 'amount')).toBe(1000);
      expect(toIntegerNumeric(1000.0, 'amount')).toBe(1000);
      expect(toIntegerNumeric('1000', 'amount')).toBe(1000);
      expect(toIntegerNumeric('1000.0', 'amount')).toBe(1000);
      expect(toIntegerNumeric('1000.00', 'amount')).toBe(1000);
    });

    it('rejects non-integer decimal values without truncating them', () => {
      expect(() => toIntegerNumeric(1000.5, 'amount')).toThrow(
        'amount must be an integer'
      );
      expect(() => toIntegerNumeric('1000.50', 'amount')).toThrow(
        'amount must be an integer'
      );
    });

    it('rejects invalid numeric values', () => {
      expect(() =>
        toIntegerNumeric(Number.POSITIVE_INFINITY, 'amount')
      ).toThrow('amount must be an integer');
      expect(() => toIntegerNumeric('abc', 'amount')).toThrow(
        'amount must be an integer'
      );
    });
  });
});
