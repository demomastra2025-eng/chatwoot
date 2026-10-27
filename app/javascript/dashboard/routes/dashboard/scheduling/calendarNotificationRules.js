import {
  APPOINTMENT_REMINDER_PRESETS,
  extractPresetKeyFromRule,
} from 'dashboard/helper/appointmentTemplatePresets';

export const APPOINTMENT_NOTIFICATION_EVENTS = [
  {
    key: 'created',
    eventName: 'appointment_created',
    anchor: 'touch.created_at',
  },
  {
    key: 'rescheduled',
    eventName: 'appointment_rescheduled',
    anchor: 'touch.created_at',
  },
  {
    key: 'updated',
    eventName: 'appointment_updated',
    anchor: 'touch.created_at',
  },
  {
    key: 'cancelled',
    eventName: 'appointment_cancelled',
    anchor: 'touch.created_at',
  },
  {
    key: 'started',
    eventName: 'appointment_created',
    anchor: 'appointment.starts_at',
  },
  {
    key: 'completed',
    eventName: 'appointment_completed',
    anchor: 'appointment.ends_at',
  },
  {
    key: 'no_show',
    eventName: 'appointment_no_show',
    anchor: 'touch.created_at',
  },
];

export const touchParams = rule => {
  const action = rule?.actions?.find(
    item => item.action_name === 'create_touch'
  );
  return Array.isArray(action?.action_params)
    ? action.action_params[0] || {}
    : action?.action_params || {};
};

export const eventKeyForRule = rule => {
  const params = touchParams(rule);
  if (
    rule?.event_name === 'appointment_created' &&
    params.relative_anchor === 'appointment.starts_at'
  )
    return 'started';
  return (
    APPOINTMENT_NOTIFICATION_EVENTS.find(
      item => item.eventName === rule?.event_name
    )?.key || 'created'
  );
};

export const presetRows = rules =>
  APPOINTMENT_REMINDER_PRESETS.filter(
    preset =>
      !(rules || []).some(rule => extractPresetKeyFromRule(rule) === preset.key)
  );

export const scheduleFor = (eventKey, timing, amount, unit) => {
  const event = APPOINTMENT_NOTIFICATION_EVENTS.find(
    item => item.key === eventKey
  );
  const seconds = Number(amount || 0) * Number(unit || 60);
  const visitAnchor =
    eventKey === 'completed' ? 'appointment.ends_at' : 'appointment.starts_at';
  let offset = 0;
  if (timing === 'before') offset = -seconds;
  if (timing === 'after') offset = seconds;
  const eventAfter =
    timing === 'after' &&
    ['created', 'rescheduled', 'updated', 'cancelled', 'no_show'].includes(
      eventKey
    );
  return {
    relative_anchor:
      timing === 'immediate' || eventAfter ? event.anchor : visitAnchor,
    relative_offset_seconds: offset,
  };
};
