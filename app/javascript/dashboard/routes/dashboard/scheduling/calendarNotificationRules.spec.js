import { describe, expect, it } from 'vitest';
import {
  eventKeyForRule,
  presetRows,
  scheduleFor,
} from './calendarNotificationRules';

describe('calendar appointment notification rules', () => {
  it('allows zero offset at the start and keeps completed notices at the visit end', () => {
    expect(scheduleFor('started', 'at_time', 0, 60)).toEqual({
      relative_anchor: 'appointment.starts_at',
      relative_offset_seconds: 0,
    });
    expect(scheduleFor('completed', 'after', 1, 3600)).toEqual({
      relative_anchor: 'appointment.ends_at',
      relative_offset_seconds: 3600,
    });
    expect(scheduleFor('rescheduled', 'after', 1, 60)).toEqual({
      relative_anchor: 'touch.created_at',
      relative_offset_seconds: 60,
    });
  });

  it('recognizes visit-start reminders and does not duplicate an existing preset', () => {
    const rule = {
      event_name: 'appointment_created',
      actions: [
        {
          action_name: 'create_touch',
          action_params: [
            {
              relative_anchor: 'appointment.starts_at',
              relative_offset_seconds: -7200,
            },
          ],
        },
      ],
    };
    expect(eventKeyForRule(rule)).toBe('started');
    expect(
      presetRows([rule]).some(
        item => item.key === 'appointment_two_hours_before'
      )
    ).toBe(false);
  });
});
