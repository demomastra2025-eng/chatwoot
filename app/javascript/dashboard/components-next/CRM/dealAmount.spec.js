import {
  formatDealAmount,
  majorAmountToMinor,
  resolveDealAmountMajor,
} from './dealAmount';

describe('formatDealAmount', () => {
  it('returns the empty value for blank amounts', () => {
    expect(formatDealAmount({ amount: null, emptyValue: '—' })).toBe('—');
    expect(formatDealAmount({ amount: '', emptyValue: '—' })).toBe('—');
  });

  it('formats zero as a valid amount', () => {
    expect(
      formatDealAmount({
        amount: 0,
        currency: 'KZT',
        locale: 'ru-RU',
      })
    ).toBe('0 KZT');
  });

  it('adds locale-aware thousands separators', () => {
    expect(
      formatDealAmount({
        amount: 1234567,
        currency: 'KZT',
        locale: 'ru-RU',
      })
    ).toBe('1\u00a0234\u00a0567 KZT');
  });
});

describe('resolveDealAmountMajor', () => {
  it('prefers API major amount over internal minor amount', () => {
    expect(
      resolveDealAmountMajor({ amount: '25000', amountMinor: 2500000 })
    ).toBe('25000');
  });

  it('falls back to converting legacy minor amount', () => {
    expect(resolveDealAmountMajor({ amountMinor: 2500000 })).toBe(25000);
  });
});

describe('majorAmountToMinor', () => {
  it('converts whole major units to internal minor units', () => {
    expect(majorAmountToMinor('25000')).toBe(2500000);
    expect(majorAmountToMinor('25000.00')).toBe(2500000);
  });

  it('rejects fractional major units', () => {
    expect(() => majorAmountToMinor('25000.50')).toThrow(
      'amount must be an integer'
    );
  });
});
