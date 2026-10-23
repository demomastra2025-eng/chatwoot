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

// The specialist price rows a service form saves. Every specialist starts
// switched off with no price, so a new service gets no specialist link unless
// a row was switched on or given a price by hand.
export const buildServicePricesPayload = (priceRows, basePrice) =>
  (priceRows || [])
    .filter(priceRow => priceRow.active || priceRow.price)
    .map(priceRow => buildServicePricePayload(priceRow, basePrice));

// One price row per specialist for the service form: a saved price row keeps
// its state, every other specialist starts switched off with no price.
export const buildServicePriceRows = (resources, prices = []) =>
  (resources || []).map(resource => {
    const matchingPrice = (prices || []).find(
      item => Number(item.resourceId) === Number(resource.id)
    );

    return {
      active: matchingPrice?.active ?? false,
      price: matchingPrice?.price || '',
      resourceId: resource.id,
      resourceName: resource.name,
    };
  });
