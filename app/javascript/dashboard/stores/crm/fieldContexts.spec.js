import { describe, expect, it, vi } from 'vitest';

import {
  APPOINTMENT_BOOKING_INTAKE_CONTEXT,
  buildCrmFieldContextOptions,
  fieldDefinitionHasContext,
  filterCrmFieldContexts,
} from './fieldContexts';

describe('fieldContexts', () => {
  const t = vi.fn(key => key);

  it('builds task and appointment context options', () => {
    expect(buildCrmFieldContextOptions('task', t)).toEqual([
      {
        label: 'CRM.SETTINGS.FIELDS.CONTEXTS.deal_task',
        value: 'deal_task',
      },
      {
        label: 'CRM.SETTINGS.FIELDS.CONTEXTS.standalone_task',
        value: 'standalone_task',
      },
    ]);

    expect(buildCrmFieldContextOptions('appointment', t)).toEqual([
      {
        label: 'CRM.SETTINGS.FIELDS.CONTEXTS.booking_intake',
        value: APPOINTMENT_BOOKING_INTAKE_CONTEXT,
      },
    ]);
  });

  it('filters unknown contexts for the selected entity kind', () => {
    expect(
      filterCrmFieldContexts(
        ['deal_task', 'booking_intake', '', null],
        'appointment',
        t
      )
    ).toEqual([APPOINTMENT_BOOKING_INTAKE_CONTEXT]);
  });

  it('detects booking intake field definitions', () => {
    expect(
      fieldDefinitionHasContext(
        {
          rules: {
            contexts: [APPOINTMENT_BOOKING_INTAKE_CONTEXT],
          },
        },
        APPOINTMENT_BOOKING_INTAKE_CONTEXT
      )
    ).toBe(true);

    expect(
      fieldDefinitionHasContext(
        {
          rules: {
            contexts: ['deal_task'],
          },
        },
        APPOINTMENT_BOOKING_INTAKE_CONTEXT
      )
    ).toBe(false);
  });
});
