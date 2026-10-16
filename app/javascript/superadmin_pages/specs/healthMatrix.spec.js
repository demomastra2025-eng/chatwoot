import {
  chartSeries,
  dayLabel,
  filterAccounts,
  statusTone,
} from '../helpers/healthMatrix';

const accounts = [
  { id: 1, name: 'Acme Inc', needs_attention: false },
  { id: 12, name: 'Клиника «Сезим»', needs_attention: true },
  { id: 3, name: 'Медцентр «Достар»', needs_attention: false },
];

describe('statusTone', () => {
  it('maps the states of the health service to the tones of the design system', () => {
    expect(statusTone('healthy')).toBe('good');
    expect(statusTone('warning')).toBe('warn');
    expect(statusTone('error')).toBe('bad');
  });

  it('shows a missing or unknown state as neutral', () => {
    expect(statusTone('none')).toBe('neutral');
    expect(statusTone(undefined)).toBe('neutral');
  });
});

describe('filterAccounts', () => {
  it('returns every clinic without a query', () => {
    expect(filterAccounts(accounts)).toHaveLength(3);
  });

  it('searches the name without case and the number as a substring', () => {
    expect(
      filterAccounts(accounts, { query: ' СЕЗИМ ' }).map(a => a.id)
    ).toEqual([12]);
    expect(filterAccounts(accounts, { query: '1' }).map(a => a.id)).toEqual([
      1, 12,
    ]);
  });

  it('keeps only the clinics that need attention', () => {
    expect(
      filterAccounts(accounts, { onlyNeedsAttention: true }).map(a => a.id)
    ).toEqual([12]);
    expect(
      filterAccounts(accounts, { query: 'acme', onlyNeedsAttention: true })
    ).toEqual([]);
  });

  it('copes with a missing list', () => {
    expect(filterAccounts(undefined, { query: 'x' })).toEqual([]);
  });
});

describe('chartSeries', () => {
  it('labels the days as dd.mm without any time zone arithmetic', () => {
    expect(dayLabel('2026-09-16')).toBe('16.09');
    expect(dayLabel('2026-01-01T23:30:00+05:00')).toBe('01.01');
    expect(dayLabel('not a day')).toBe('not a day');
  });

  it('turns the [day, count] pairs into labels and values', () => {
    expect(
      chartSeries([
        ['2026-09-16', 3],
        ['2026-09-17', '5'],
        ['2026-09-18', null],
      ])
    ).toEqual({ labels: ['16.09', '17.09', '18.09'], values: [3, 5, 0] });
  });

  it('is empty for no data', () => {
    expect(chartSeries(undefined)).toEqual({ labels: [], values: [] });
  });
});
