import { describe, expect, it } from 'vitest';

import {
  buildServicePricePayload,
  resolveDraftServicePrice,
} from './servicePricing';

describe('servicePricing', () => {
  it('fills an empty active specialist price from the service base price', () => {
    expect(
      resolveDraftServicePrice({
        active: true,
        basePrice: 15000,
        price: '',
      })
    ).toBe(15000);
  });

  it('keeps the explicit specialist price when it is already set', () => {
    expect(
      resolveDraftServicePrice({
        active: true,
        basePrice: 15000,
        price: 22000,
      })
    ).toBe(22000);
  });

  it('builds the payload with the base price for active empty specialist prices', () => {
    expect(
      buildServicePricePayload(
        {
          active: true,
          compensationPercent: 0,
          compensationType: 'percent',
          compensationValue: 40,
          price: '',
          resourceId: 7,
        },
        18000
      )
    ).toEqual({
      active: true,
      compensation_percent: 0,
      compensation_type: 'percent',
      compensation_value: 40,
      price: 18000,
      resource_id: 7,
    });
  });
});
