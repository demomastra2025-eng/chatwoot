import { describe, expect, it } from 'vitest';

import {
  buildServicePricePayload,
  buildServicePriceRows,
  buildServicePricesPayload,
  resolveDraftServicePrice,
} from './servicePricing';

describe('servicePricing', () => {
  const resources = [
    { id: 7, name: 'Айгерим' },
    { id: 8, name: 'Дана' },
    { id: 9, name: 'Ержан' },
  ];

  it('starts every specialist of a new service switched off with no price', () => {
    expect(buildServicePriceRows(resources)).toEqual([
      { active: false, price: '', resourceId: 7, resourceName: 'Айгерим' },
      { active: false, price: '', resourceId: 8, resourceName: 'Дана' },
      { active: false, price: '', resourceId: 9, resourceName: 'Ержан' },
    ]);
  });

  it('links a new service to no specialist when no row was touched', () => {
    expect(
      buildServicePricesPayload(buildServicePriceRows(resources, []), 18000)
    ).toEqual([]);
  });

  it('saves only the specialists switched on or priced by hand', () => {
    const rows = buildServicePriceRows(resources, []);
    rows[0].active = true;
    rows[2].price = 25000;

    expect(buildServicePricesPayload(rows, 18000)).toEqual([
      { active: true, price: 18000, resource_id: 7 },
      { active: false, price: 25000, resource_id: 9 },
    ]);
  });

  it('keeps the saved price rows of an existing service and adds none', () => {
    const rows = buildServicePriceRows(resources, [
      { active: true, price: 21000, resourceId: 8 },
    ]);

    expect(rows[1]).toEqual({
      active: true,
      price: 21000,
      resourceId: 8,
      resourceName: 'Дана',
    });
    expect(buildServicePricesPayload(rows, 18000)).toEqual([
      { active: true, price: 21000, resource_id: 8 },
    ]);
  });

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
          price: '',
          resourceId: 7,
        },
        18000
      )
    ).toEqual({
      active: true,
      price: 18000,
      resource_id: 7,
    });
  });

  it('normalizes decimal-zero price values', () => {
    expect(
      buildServicePricePayload(
        {
          active: true,
          price: '21000.00',
          resourceId: 7,
        },
        18000
      )
    ).toEqual({
      active: true,
      price: 21000,
      resource_id: 7,
    });
  });

  it('does not send the specialist rate keys in the price payload', () => {
    const payload = buildServicePricePayload(
      {
        active: true,
        compensationPercent: 10,
        compensationType: 'fixed_plus_percent',
        compensationValue: 3000,
        price: 21000,
        resourceId: 7,
      },
      18000
    );

    expect(Object.keys(payload).sort()).toEqual([
      'active',
      'price',
      'resource_id',
    ]);
  });

  it('rejects fractional price values without truncating them', () => {
    expect(() =>
      buildServicePricePayload(
        {
          active: true,
          price: '21000.50',
          resourceId: 7,
        },
        18000
      )
    ).toThrow('price must be an integer');
  });
});
