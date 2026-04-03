import { describe, expect, it } from 'vitest';

import { preserveCustomAttributeKeys } from './preserveCustomAttributeKeys';

describe('preserveCustomAttributeKeys', () => {
  it('keeps nested custom attribute keys in snake_case while camel-casing outer record keys', () => {
    const source = {
      custom_attributes: {
        follow_up_on: '2026-03-10',
        visit_reason: 'follow_up',
      },
      resource_id: 7,
      starts_at: '2026-03-09T09:00:00.000Z',
    };

    const normalized = preserveCustomAttributeKeys(source, {
      customAttributes: {
        followUpOn: '2026-03-10',
        visitReason: 'follow_up',
      },
      resourceId: 7,
      startsAt: '2026-03-09T09:00:00.000Z',
    });

    expect(normalized).toEqual({
      customAttributes: {
        follow_up_on: '2026-03-10',
        visit_reason: 'follow_up',
      },
      resourceId: 7,
      startsAt: '2026-03-09T09:00:00.000Z',
    });
  });

  it('preserves custom attribute keys recursively inside payload arrays', () => {
    const source = {
      appointments: [
        {
          custom_attributes: {
            triage_at: '2026-03-09T10:15:00+05:00',
          },
          id: 3,
        },
      ],
    };

    const normalized = preserveCustomAttributeKeys(source, {
      appointments: [
        {
          customAttributes: {
            triageAt: '2026-03-09T10:15:00+05:00',
          },
          id: 3,
        },
      ],
    });

    expect(normalized).toEqual({
      appointments: [
        {
          customAttributes: {
            triage_at: '2026-03-09T10:15:00+05:00',
          },
          id: 3,
        },
      ],
    });
  });

  it('keeps nested custom attribute keys when the outer record is already camel-cased', () => {
    const source = {
      customAttributes: {
        visit_reason: 'follow_up',
      },
      resourceId: 7,
    };

    const normalized = preserveCustomAttributeKeys(source, {
      customAttributes: {
        visitReason: 'follow_up',
      },
      resourceId: 7,
    });

    expect(normalized).toEqual({
      customAttributes: {
        visit_reason: 'follow_up',
      },
      resourceId: 7,
    });
  });
});
