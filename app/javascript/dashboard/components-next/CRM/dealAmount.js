const INTEGER_MAJOR_AMOUNT_PATTERN = /^[+-]?\d+(?:[,.]0+)?$/;

export const resolveDealAmountMajor = deal => {
  const amount = deal?.amount;

  if (amount !== '' && amount !== null && amount !== undefined) {
    return amount;
  }

  const amountMinor = deal?.amountMinor;

  if (amountMinor === '' || amountMinor === null || amountMinor === undefined) {
    return undefined;
  }

  const numericAmountMinor = Number(amountMinor);

  if (!Number.isFinite(numericAmountMinor)) {
    return undefined;
  }

  return numericAmountMinor / 100;
};

export const majorAmountToMinor = value => {
  if (value === '' || value === null || value === undefined) {
    return 0;
  }

  if (typeof value === 'number') {
    if (!Number.isFinite(value) || !Number.isInteger(value)) {
      throw new Error('amount must be an integer');
    }

    return value * 100;
  }

  const text = String(value).trim();

  if (!INTEGER_MAJOR_AMOUNT_PATTERN.test(text)) {
    throw new Error('amount must be an integer');
  }

  return Number.parseInt(text.replace(',', '.'), 10) * 100;
};

export const formatDealAmount = ({
  amount,
  currency,
  emptyValue = '—',
  locale,
}) => {
  if (
    amount === '' ||
    amount === null ||
    amount === undefined ||
    (typeof amount === 'string' && amount.trim() === '')
  ) {
    return emptyValue;
  }

  const numericAmount = Number(amount);

  if (!Number.isFinite(numericAmount)) {
    return emptyValue;
  }

  const hasFraction = !Number.isInteger(numericAmount);
  const formattedAmount = new Intl.NumberFormat(locale, {
    maximumFractionDigits: hasFraction ? 2 : 0,
    minimumFractionDigits: 0,
  }).format(numericAmount);

  return currency ? `${formattedAmount} ${currency}` : formattedAmount;
};
