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
