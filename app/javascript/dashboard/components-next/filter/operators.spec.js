import { useOperators } from './operators';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

describe('useOperators', () => {
  it('returns comparison operators for numeric-like custom attribute types', () => {
    const { getOperatorTypes, comparisonOperators } = useOperators();

    expect(getOperatorTypes('number')).toEqual(comparisonOperators.value);
    expect(getOperatorTypes('currency')).toEqual(comparisonOperators.value);
    expect(getOperatorTypes('percent')).toEqual(comparisonOperators.value);
  });

  it('keeps existing operator behavior for date type', () => {
    const { getOperatorTypes, comparisonOperators } = useOperators();

    expect(getOperatorTypes('date')).toEqual(comparisonOperators.value);
  });
});
