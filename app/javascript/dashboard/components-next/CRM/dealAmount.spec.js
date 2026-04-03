import { formatDealAmount } from './dealAmount';

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
