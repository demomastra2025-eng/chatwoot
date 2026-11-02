import { describe, expect, it } from 'vitest';
import {
  eventKeyForRule,
  findPresetRuleForInbox,
  presetRows,
  scheduleFor,
} from './calendarNotificationRules';

describe('calendar appointment notification rules', () => {
  const presetRule = (id, inboxId) => ({
    id,
    description: '[scheduling_preset:appointment_created]',
    actions: [
      {
        action_name: 'create_touch',
        action_params: [{ target_inbox_id: inboxId }],
      },
    ],
  });

  it('does not substitute a matching preset from another channel or a channel-less legacy rule', () => {
    expect(
      findPresetRuleForInbox(
        [presetRule(1, 3), presetRule(2, null)],
        'appointment_created',
        4
      )
    ).toBeUndefined();
    expect(
      findPresetRuleForInbox([presetRule(1, 3)], 'appointment_created', '')
    ).toBeUndefined();
  });

  it('selects the oldest matching rule within the channel without reordering the source list', () => {
    const rules = [presetRule(8, '4'), presetRule(1, 3), presetRule(6, 4)];
    expect(findPresetRuleForInbox(rules, 'appointment_created', '4')?.id).toBe(
      6
    );
    expect(rules.map(rule => rule.id)).toEqual([8, 1, 6]);
  });

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
