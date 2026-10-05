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
    price: toIntegerNumeric(resolvedPrice, 'price') || 0,
    resource_id: priceRow.resourceId,
  };
};
