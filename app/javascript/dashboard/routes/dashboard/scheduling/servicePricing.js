import { toNumeric } from 'dashboard/stores/scheduling/shared';

export const resolveDraftServicePrice = ({ active, basePrice, price }) => {
  const numericPrice = toNumeric(price);
  if (!active || numericPrice !== undefined) {
    return price;
  }

  const numericBasePrice = toNumeric(basePrice);
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
    compensation_percent: toNumeric(priceRow.compensationPercent) || 0,
    compensation_type: priceRow.compensationType,
    compensation_value: toNumeric(priceRow.compensationValue) || 0,
    price: toNumeric(resolvedPrice) || 0,
    resource_id: priceRow.resourceId,
  };
};
