import { toIntegerNumeric } from 'dashboard/stores/scheduling/shared';

export const resolveDraftServicePrice = ({ active, basePrice, price }) => {
  const numericPrice = toIntegerNumeric(price, 'price');
  if (!active || numericPrice !== undefined) {
    return price;
  }

  const numericBasePrice = toIntegerNumeric(basePrice, 'base_price');
  return numericBasePrice === undefined ? '' : numericBasePrice;
};

export const buildServicePricePayload = (priceRow, basePrice) => {
  const resolvedPrice = resolveDraftServicePrice({
    active: priceRow.active,
    basePrice,
    price: priceRow.price,
  });

  return {
    active: priceRow.active,
    compensation_percent:
      toIntegerNumeric(priceRow.compensationPercent, 'compensation_percent') ||
      0,
    compensation_type: priceRow.compensationType,
    compensation_value:
      toIntegerNumeric(priceRow.compensationValue, 'compensation_value') || 0,
    price: toIntegerNumeric(resolvedPrice, 'price') || 0,
    resource_id: priceRow.resourceId,
  };
};
