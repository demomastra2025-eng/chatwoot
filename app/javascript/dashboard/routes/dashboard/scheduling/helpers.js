import {
  addDays,
  addMonths,
  addWeeks,
  endOfDay,
  endOfMonth,
  endOfWeek,
  format,
  isSameDay,
  parseISO,
  startOfDay,
  startOfMonth,
  startOfWeek,
} from 'date-fns';

import {
  DEFAULT_VISIBLE_END_MINUTE,
  DEFAULT_VISIBLE_START_MINUTE,
  MINUTE_STEP,
} from './constants';

const WEEK_STARTS_ON = 1;
const normalizeLocale = locale => locale?.replace(/_/g, '-') || undefined;

const formatLocalizedDate = (value, locale, options) =>
  new Intl.DateTimeFormat(normalizeLocale(locale), options).format(value);

const firstPresentValue = (source, keys) =>
  keys.reduce((value, key) => value || source?.[key], '');

const numericId = value => {
  const id = Number(value);
  return Number.isFinite(id) && id > 0 ? id : 0;
};

const displayId = value => String(value || '').replace(/[^\d]/g, '');

export const canCreateAppointmentConversation = appointment =>
  appointment?.conversationCreationSupported === true &&
  (appointment?.source !== 'medelement' ||
    appointment?.externalConversationCreationSupported === true);

export const isAppointmentProviderOwned = appointment =>
  appointment?.source === 'medelement';

export const resolveAppointmentConversationTarget = appointment => {
  const explicitConversationId = numericId(
    firstPresentValue(appointment, [
      'appointmentConversationId',
      'appointment_conversation_id',
      'conversationId',
      'conversation_id',
    ])
  );
  const hasExplicitConversation = explicitConversationId > 0;
  const conversationId =
    explicitConversationId ||
    numericId(
      firstPresentValue(appointment, [
        'chatConversationId',
        'chat_conversation_id',
      ])
    );
  const explicitConversationDisplayId = displayId(
    firstPresentValue(appointment, [
      'appointmentConversationDisplayId',
      'appointment_conversation_display_id',
      'conversationDisplayId',
      'conversation_display_id',
    ])
  );
  const conversationDisplayId = hasExplicitConversation
    ? explicitConversationDisplayId
    : displayId(
        firstPresentValue(appointment, [
          'chatConversationDisplayId',
          'chat_conversation_display_id',
        ])
      );
  const threadIdKeys = [
    'appointmentCommunicationThreadId',
    'appointment_communication_thread_id',
  ];
  const threadDisplayIdKeys = [
    'appointmentCommunicationThreadDisplayId',
    'appointment_communication_thread_display_id',
  ];

  if (!hasExplicitConversation) {
    threadIdKeys.push('communicationThreadId', 'communication_thread_id');
    threadDisplayIdKeys.push(
      'communicationThreadDisplayId',
      'communication_thread_display_id'
    );
  }

  return {
    communicationThreadDisplayId: displayId(
      firstPresentValue(appointment, threadDisplayIdKeys)
    ),
    communicationThreadId: displayId(
      firstPresentValue(appointment, threadIdKeys)
    ),
    conversationDisplayId,
    conversationId,
  };
};

export const toDate = value => {
  if (value instanceof Date) return value;
  if (!value) return new Date();

  try {
    return parseISO(value);
  } catch {
    return new Date(value);
  }
};

export const formatDateKey = value => format(toDate(value), 'yyyy-MM-dd');

export const buildCalendarRange = (view, anchorDate) => {
  const date = toDate(anchorDate);

  switch (view) {
    case 'day':
      return {
        from: startOfDay(date),
        to: endOfDay(date),
      };
    case 'month':
      return {
        from: startOfWeek(startOfMonth(date), { weekStartsOn: WEEK_STARTS_ON }),
        to: endOfWeek(endOfMonth(date), { weekStartsOn: WEEK_STARTS_ON }),
      };
    case 'list':
    case 'kanban':
      return {
        from: startOfDay(date),
        to: endOfDay(addDays(date, 13)),
      };
    case 'week':
    default:
      return {
        from: startOfWeek(date, { weekStartsOn: WEEK_STARTS_ON }),
        to: endOfWeek(date, { weekStartsOn: WEEK_STARTS_ON }),
      };
  }
};

export const shiftAnchorDate = (view, anchorDate, direction) => {
  const date = toDate(anchorDate);

  switch (view) {
    case 'day':
      return addDays(date, direction);
    case 'month':
      return addMonths(date, direction);
    case 'list':
    case 'kanban':
      return addDays(date, direction * 14);
    case 'week':
    default:
      return addWeeks(date, direction);
  }
};

export const formatCalendarTitle = (view, anchorDate, locale) => {
  const { from, to } = buildCalendarRange(view, anchorDate);

  if (view === 'day') {
    return formatLocalizedDate(from, locale, {
      day: 'numeric',
      month: 'long',
      weekday: 'long',
      year: 'numeric',
    });
  }

  if (view === 'month') {
    return formatLocalizedDate(from, locale, {
      month: 'long',
      year: 'numeric',
    });
  }

  return `${formatLocalizedDate(from, locale, {
    day: 'numeric',
    month: 'short',
  })} - ${formatLocalizedDate(to, locale, {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  })}`;
};

export const buildDayListForView = (view, anchorDate) => {
  const { from, to } = buildCalendarRange(view, anchorDate);
  const days = [];

  let cursor = startOfDay(from);
  while (cursor <= to) {
    days.push(cursor);
    cursor = addDays(cursor, 1);
  }

  return days;
};

export const buildCalendarColumns = (view, anchorDate, resources) => {
  const days = buildDayListForView(
    view === 'month' ? 'month' : view,
    anchorDate
  );

  if (view === 'month' || view === 'list') {
    return days.map(day => ({
      id: formatDateKey(day),
      date: day,
      dateKey: formatDateKey(day),
      resourceId: null,
      resourceName: null,
    }));
  }

  return days.flatMap(day => {
    return resources.map(resource => ({
      id: `${resource.id}-${formatDateKey(day)}`,
      date: day,
      dateKey: formatDateKey(day),
      resourceId: resource.id,
      resourceName: resource.name,
      resourceColor: resource.color,
      timezone: resource.timezone,
    }));
  });
};

export const formatTimeLabel = minute => {
  const hours = Math.floor(minute / 60)
    .toString()
    .padStart(2, '0');
  const minutes = Math.floor(minute % 60)
    .toString()
    .padStart(2, '0');

  return `${hours}:${minutes}`;
};

export const minuteOfDayFromDate = value => {
  const date = toDate(value);
  return date.getHours() * 60 + date.getMinutes();
};

export const clampMinute = minute => {
  return Math.max(0, Math.min(24 * 60, minute));
};

export const snapMinute = (minute, step = MINUTE_STEP) => {
  return clampMinute(Math.round(minute / step) * step);
};

export const toDateTimeInputValue = value => {
  if (!value) return '';
  return format(toDate(value), "yyyy-MM-dd'T'HH:mm");
};

export const fromDateTimeInputValue = value => {
  if (!value) return null;
  return new Date(value).toISOString();
};

export const deriveVisibleMinuteWindow = ({
  columns,
  workRules,
  workdayOverrides,
  appointments = [],
}) => {
  const relevantMinutes = [];

  columns.forEach(column => {
    const override = workdayOverrides.find(item => {
      return (
        item.resourceId === column.resourceId && item.date === column.dateKey
      );
    });

    if (override) {
      if (
        Number.isFinite(override.startMinute) &&
        Number.isFinite(override.endMinute) &&
        override.endMinute > override.startMinute
      ) {
        relevantMinutes.push(override.startMinute, override.endMinute);
      }
      return;
    }

    workRules
      .filter(rule => {
        return (
          rule.resourceId === column.resourceId &&
          rule.weekday === column.date.getDay() &&
          rule.active
        );
      })
      .forEach(rule => {
        relevantMinutes.push(rule.startMinute, rule.endMinute);
      });
  });

  appointments.forEach(appointment => {
    relevantMinutes.push(
      minuteOfDayFromDate(appointment.startsAt),
      minuteOfDayFromDate(appointment.endsAt)
    );
  });

  const normalizedRelevantMinutes = relevantMinutes.filter(Number.isFinite);

  if (normalizedRelevantMinutes.length === 0) {
    return {
      startMinute: DEFAULT_VISIBLE_START_MINUTE,
      endMinute: DEFAULT_VISIBLE_END_MINUTE,
    };
  }

  const startMinute = clampMinute(
    Math.min(
      DEFAULT_VISIBLE_START_MINUTE,
      Math.floor(Math.min(...normalizedRelevantMinutes) / MINUTE_STEP) *
        MINUTE_STEP
    )
  );
  const endMinute = clampMinute(
    Math.max(
      DEFAULT_VISIBLE_END_MINUTE,
      Math.ceil(Math.max(...normalizedRelevantMinutes) / MINUTE_STEP) *
        MINUTE_STEP
    )
  );

  return {
    startMinute,
    endMinute: Math.max(endMinute, startMinute + MINUTE_STEP),
  };
};

export const dayMatchesHoliday = (holiday, day) => {
  const date = toDate(holiday.date);

  if (holiday.recurringYearly) {
    return (
      date.getMonth() === day.getMonth() && date.getDate() === day.getDate()
    );
  }

  return isSameDay(date, day);
};

export const clipIntervalToDay = (startsAt, endsAt, day) => {
  const dayStart = startOfDay(day);
  const dayEnd = endOfDay(day);
  const intervalStart = startsAt > dayStart ? startsAt : dayStart;
  const intervalEnd = endsAt < dayEnd ? endsAt : dayEnd;

  if (intervalStart >= intervalEnd) {
    return null;
  }

  return {
    startMinute: minuteOfDayFromDate(intervalStart),
    endMinute: minuteOfDayFromDate(intervalEnd),
  };
};

export const buildTimeOffIntervals = (timeOffs, column) => {
  return timeOffs
    .filter(
      item => item.resourceId === null || item.resourceId === column.resourceId
    )
    .map(item => {
      return clipIntervalToDay(
        toDate(item.startsAt),
        toDate(item.endsAt),
        column.date
      );
    })
    .filter(Boolean);
};

export const buildBreakIntervals = (breakRules, workdayOverrides, column) => {
  const override = workdayOverrides.find(item => {
    return (
      item.resourceId === column.resourceId && item.date === column.dateKey
    );
  });

  if (
    override &&
    override.breakStartMinute !== null &&
    override.breakStartMinute !== undefined &&
    override.breakEndMinute !== null &&
    override.breakEndMinute !== undefined
  ) {
    return [
      {
        startMinute: override.breakStartMinute,
        endMinute: override.breakEndMinute,
        title: override.breakTitle,
      },
    ];
  }

  return breakRules
    .filter(rule => {
      return (
        rule.resourceId === column.resourceId &&
        rule.weekday === column.date.getDay() &&
        rule.active
      );
    })
    .map(rule => ({
      startMinute: rule.startMinute,
      endMinute: rule.endMinute,
      title: rule.title,
    }));
};

export const getAppointmentsForColumn = (appointments, column) => {
  return appointments.filter(appointment => {
    if (appointment.resourceId !== column.resourceId) return false;

    const startsAt = toDate(appointment.startsAt);
    const endsAt = toDate(appointment.endsAt);
    const dayStart = startOfDay(column.date);
    const dayEnd = endOfDay(column.date);

    return startsAt < dayEnd && endsAt > dayStart;
  });
};

export const formatCurrency = value => {
  return new Intl.NumberFormat('ru-RU').format(Number(value || 0));
};

export const getServicePriceForResource = (service, resourceId) => {
  if (!service) return 0;

  const matchingPrice = (service.prices || []).find(price => {
    return (
      Number(price.resourceId) === Number(resourceId) &&
      price.active !== false &&
      Number(price.price || 0) > 0
    );
  });

  return Number(matchingPrice?.price || service.basePrice || 0);
};
