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
import { utcToZonedTime, zonedTimeToUtc } from 'date-fns-tz';

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

export const hasMedelementReceptionIdentity = appointment =>
  appointment?.externalRef?.startsWith('medelement:reception:') ||
  Boolean(appointment?.customAttributes?.medelement_reception_code) ||
  ['pending', 'succeeded', 'provider_status_unknown'].includes(
    appointment?.providerConfirmationStatus ||
      appointment?.customAttributes?.medelement_provider_sync_status
  );

export const providerBookingNeedsReview = appointment =>
  ['failed', 'provider_status_unknown'].includes(
    appointment?.providerConfirmationStatus ||
      appointment?.customAttributes?.medelement_provider_sync_status
  ) && ['scheduled', 'confirmed', 'cancelled'].includes(appointment?.status);

const providerCancellationCommandId = appointment =>
  appointment?.customAttributes?.medelement_cancellation_command_id;

export const providerCancellationPending = appointment =>
  appointment?.status !== 'cancelled' &&
  Boolean(providerCancellationCommandId(appointment)) &&
  (appointment?.providerConfirmationStatus ||
    appointment?.customAttributes?.medelement_provider_sync_status) ===
    'pending';

// Cancelled in OneLink only: the reception is still active in MedElement.
export const isMedelementLocalCancellation = appointment =>
  appointment?.status === 'cancelled' &&
  Boolean(appointment?.customAttributes?.medelement_local_cancellation);

// Cancelling will stay in OneLink (hook setting remove_reception_on_cancel is off).
export const isMedelementCancellationLocalOnly = appointment =>
  appointment?.medelementCancellationMode === 'local_only';

export const providerBookingStatusKey = appointment => {
  if (isMedelementLocalCancellation(appointment))
    return 'SCHEDULING.APPOINTMENT_STATUS.MEDELEMENT_NOT_CANCELLED';
  if (providerBookingNeedsReview(appointment))
    return providerCancellationCommandId(appointment) ||
      appointment?.status === 'cancelled'
      ? 'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW'
      : 'SCHEDULING.APPOINTMENT_STATUS.PROVIDER_REVIEW';
  if (providerCancellationPending(appointment))
    return 'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_PENDING';
  if (
    appointment?.status === 'cancelled' &&
    (appointment?.providerConfirmationStatus ||
      appointment?.customAttributes?.medelement_provider_sync_status) ===
      'pending'
  )
    return 'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_PENDING';

  return '';
};

export const providerBookingStatusMessage = (appointment, t) => {
  const key = providerBookingStatusKey(appointment);
  if (key === 'SCHEDULING.APPOINTMENT_STATUS.MEDELEMENT_NOT_CANCELLED')
    return t('SCHEDULING.APPOINTMENT_STATUS.MEDELEMENT_NOT_CANCELLED');
  if (key === 'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW')
    return t('SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW');
  if (key === 'SCHEDULING.APPOINTMENT_STATUS.PROVIDER_REVIEW')
    return t('SCHEDULING.APPOINTMENT_STATUS.PROVIDER_REVIEW');
  if (key === 'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_PENDING')
    return t('SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_PENDING');

  return '';
};

export const appointmentCancellationAlertKey = appointment => {
  if (isMedelementLocalCancellation(appointment))
    return 'SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL_LOCAL_ONLY';
  const providerStatus =
    appointment?.providerConfirmationStatus ||
    appointment?.customAttributes?.medelement_provider_sync_status;
  if (
    (providerCancellationCommandId(appointment) ||
      appointment?.status === 'cancelled') &&
    providerBookingNeedsReview(appointment)
  )
    return 'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW';
  if (
    providerStatus === 'pending' &&
    (providerCancellationCommandId(appointment) ||
      appointment?.status === 'cancelled')
  )
    return 'SCHEDULING.APPOINTMENT_FORM.CANCELLATION_PENDING';
  return appointment?.status === 'cancelled'
    ? 'SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL'
    : 'SCHEDULING.MEDELEMENT.QUEUED';
};

export const appointmentCancellationAlertMessage = (appointment, t) => {
  const key = appointmentCancellationAlertKey(appointment);
  if (key === 'SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL_LOCAL_ONLY')
    return t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL_LOCAL_ONLY');
  if (key === 'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW')
    return t('SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW');
  if (key === 'SCHEDULING.APPOINTMENT_FORM.CANCELLATION_PENDING')
    return t('SCHEDULING.APPOINTMENT_FORM.CANCELLATION_PENDING');
  if (key === 'SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL')
    return t('SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL');

  return t('SCHEDULING.MEDELEMENT.QUEUED');
};

export const medelementCabinetsForResource = resource => {
  const customAttributes = resource?.customAttributes || {};
  const cabinets =
    customAttributes.medelement_cabinets ||
    customAttributes.medelementCabinets ||
    [];

  return Array.isArray(cabinets)
    ? cabinets
        .map(cabinet => ({
          code: String(
            cabinet?.companyCabinetCode ||
              cabinet?.company_cabinet_code ||
              cabinet?.COMPANY_CABINET_CODE ||
              ''
          ),
          name: String(
            cabinet?.cabinetName ||
              cabinet?.cabinet_name ||
              cabinet?.companyCabinetName ||
              cabinet?.company_cabinet_name ||
              cabinet?.name ||
              ''
          ),
          number: String(
            cabinet?.cabinetNumber || cabinet?.cabinet_number || ''
          ),
        }))
        .filter(cabinet => cabinet.code)
    : [];
};

export const isMedelementResource = resource => {
  const customAttributes = resource?.customAttributes || {};

  return Boolean(
    customAttributes.medelement_specialist_code ||
      customAttributes.medelementSpecialistCode ||
      medelementCabinetsForResource(resource).length
  );
};

export const resolveAppointmentMedelementCabinetCode = (
  appointment,
  resources = []
) => {
  const customAttributes = appointment?.customAttributes || {};
  const explicitCode =
    customAttributes.medelement_cabinet_code ||
    customAttributes.medelementCabinetCode;
  if (explicitCode) return String(explicitCode);

  const resource = resources.find(
    item => Number(item.id) === Number(appointment?.resourceId)
  );
  const cabinets = medelementCabinetsForResource(resource);

  return cabinets.length === 1 ? cabinets[0].code : '';
};

export const buildMedelementProviderCommandDetails = ({
  appointment = {},
  params = {},
}) => {
  const customAttributes = appointment.customAttributes || {};
  const serviceNames = Array(appointment.services)
    .map(service => service?.name)
    .filter(Boolean);

  return {
    cabinetCode:
      params.company_cabinet_code ||
      customAttributes.medelement_cabinet_code ||
      customAttributes.medelementCabinetCode ||
      '',
    currentEndsAt: appointment.endsAt || '',
    currentStartsAt: appointment.startsAt || '',
    desiredEndsAt: params.desired_ends_at || '',
    desiredStartsAt: params.desired_starts_at || '',
    durationMin:
      appointment.durationMin || appointment.serviceDurationMinSnapshot || null,
    operation: params.operation || '',
    patientName: appointment.clientName || appointment.title || '',
    price: appointment.serviceAmount ?? null,
    serviceName:
      appointment.serviceNameSnapshot || serviceNames.join(', ') || '',
    specialistName: appointment.resourceName || '',
  };
};

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

// Routes use public display IDs. A database ID alone cannot identify a chat URL.
export const appointmentPatientDialogRoute = (appointment, accountId) => {
  const target = resolveAppointmentConversationTarget(appointment);
  const ownerId = numericId(appointment?.contactId || appointment?.contact_id);
  const patientId = numericId(
    appointment?.patientContextContactId ||
      appointment?.patient_context_contact_id ||
      appointment?.patientContactId ||
      appointment?.patient_contact_id ||
      ownerId
  );
  if (!ownerId || !patientId || !numericId(accountId)) return null;
  const query = {
    patientContactId: String(patientId),
    patientChatContactId: String(ownerId),
  };
  if (target.communicationThreadDisplayId) {
    return {
      name: 'communication_thread_conversation',
      params: {
        accountId,
        communication_thread_id: target.communicationThreadDisplayId,
      },
      query,
    };
  }
  if (target.conversationDisplayId) {
    return {
      name: 'inbox_conversation',
      params: { accountId, conversation_id: target.conversationDisplayId },
      query,
    };
  }
  return null;
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

export const buildCalendarRange = (view, anchorDate, timezone) => {
  const date = timezone
    ? utcToZonedTime(toDate(anchorDate), timezone)
    : toDate(anchorDate);
  let range;

  switch (view) {
    case 'day':
      range = {
        from: startOfDay(date),
        to: endOfDay(date),
      };
      break;
    case 'month':
      range = {
        from: startOfWeek(startOfMonth(date), { weekStartsOn: WEEK_STARTS_ON }),
        to: endOfWeek(endOfMonth(date), { weekStartsOn: WEEK_STARTS_ON }),
      };
      break;
    case 'list':
    case 'kanban':
      range = {
        from: startOfDay(date),
        to: endOfDay(addDays(date, 13)),
      };
      break;
    case 'week':
    default:
      range = {
        from: startOfWeek(date, { weekStartsOn: WEEK_STARTS_ON }),
        to: endOfWeek(date, { weekStartsOn: WEEK_STARTS_ON }),
      };
  }

  if (!timezone) return range;

  return {
    from: zonedTimeToUtc(range.from, timezone),
    to: zonedTimeToUtc(range.to, timezone),
  };
};

export const shiftAnchorDate = (view, anchorDate, direction, timezone) => {
  const date = timezone
    ? utcToZonedTime(toDate(anchorDate), timezone)
    : toDate(anchorDate);
  let shiftedDate;

  switch (view) {
    case 'day':
      shiftedDate = addDays(date, direction);
      break;
    case 'month':
      shiftedDate = addMonths(date, direction);
      break;
    case 'list':
    case 'kanban':
      shiftedDate = addDays(date, direction * 14);
      break;
    case 'week':
    default:
      shiftedDate = addWeeks(date, direction);
  }

  return timezone ? zonedTimeToUtc(shiftedDate, timezone) : shiftedDate;
};

// Date pickers return a browser-local calendar day. Anchor it at noon of the
// same calendar day in the workspace timezone so the selected day never moves
// when the browser timezone differs from the workspace timezone.
export const calendarDayAnchor = (pickedDate, timezone) => {
  const date = toDate(pickedDate);
  const noon = new Date(
    date.getFullYear(),
    date.getMonth(),
    date.getDate(),
    12,
    0,
    0,
    0
  );

  return timezone ? zonedTimeToUtc(noon, timezone) : noon;
};

// Use the workspace's calendar day for the Today control. Unlike a picked
// date, the current instant must first be converted out of the browser zone.
export const calendarTodayAnchor = (now, timezone) => {
  const date = toDate(now);
  return calendarDayAnchor(
    timezone ? utcToZonedTime(date, timezone) : date,
    timezone
  );
};

export const formatCalendarTitle = (view, anchorDate, locale, timezone) => {
  const range = buildCalendarRange(view, anchorDate, timezone);
  const calendarOptions = options =>
    timezone ? { ...options, timeZone: timezone } : options;

  if (view === 'day') {
    return formatLocalizedDate(
      timezone ? toDate(anchorDate) : range.from,
      locale,
      calendarOptions({
        day: 'numeric',
        month: 'long',
        weekday: 'long',
        year: 'numeric',
      })
    );
  }

  if (view === 'month') {
    return formatLocalizedDate(
      timezone ? toDate(anchorDate) : range.from,
      locale,
      calendarOptions({
        month: 'long',
        year: 'numeric',
      })
    );
  }

  return `${formatLocalizedDate(
    range.from,
    locale,
    calendarOptions({
      day: 'numeric',
      month: 'short',
    })
  )} - ${formatLocalizedDate(
    range.to,
    locale,
    calendarOptions({
      day: 'numeric',
      month: 'short',
      year: 'numeric',
    })
  )}`;
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

// Wall-clock parts of an instant in a timezone. Read through Intl instead of
// a zoned local Date, so a time inside the browser's own DST gap (e.g. 02:30
// in Berlin on the last Sunday of March) is not shifted by an hour.
const zonedWallClockParts = (value, timezone) => {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  })
    .formatToParts(toDate(value))
    .reduce((result, part) => {
      result[part.type] = part.value;
      return result;
    }, {});

  return {
    year: parts.year,
    month: parts.month,
    day: parts.day,
    // Some engines print midnight as "24" even with h23.
    hour: parts.hour === '24' ? '00' : parts.hour,
    minute: parts.minute,
  };
};

// With a timezone the minute of day is read on the workspace clock, like the
// calendar grid; without one it stays browser-local.
export const minuteOfDayFromDate = (value, timezone) => {
  if (timezone) {
    const { hour, minute } = zonedWallClockParts(value, timezone);
    return Number(hour) * 60 + Number(minute);
  }
  const date = toDate(value);
  return date.getHours() * 60 + date.getMinutes();
};

export const clampMinute = minute => {
  return Math.max(0, Math.min(24 * 60, minute));
};

export const snapMinute = (minute, step = MINUTE_STEP) => {
  return clampMinute(Math.round(minute / step) * step);
};

const DATE_TIME_INPUT_FORMAT = "yyyy-MM-dd'T'HH:mm";

// Date/time inputs hold a wall-clock "yyyy-MM-ddTHH:mm" value. With a
// timezone (the scheduling workspace timezone) that wall clock is read and
// written in that zone, so a form shows the same time as the calendar grid in
// any browser timezone; without one it stays browser-local (snooze, touches,
// CRM tasks).
export const toDateTimeInputValue = (value, timezone) => {
  if (!value) return '';
  if (timezone) {
    const { year, month, day, hour, minute } = zonedWallClockParts(
      value,
      timezone
    );
    return `${year}-${month}-${day}T${hour}:${minute}`;
  }
  return format(toDate(value), DATE_TIME_INPUT_FORMAT);
};

export const fromDateTimeInputValue = (value, timezone) => {
  if (!value) return null;
  const date = timezone ? zonedTimeToUtc(value, timezone) : new Date(value);
  return date.toISOString();
};

// Moves a date/time input value by a duration on the real clock (the same
// instant arithmetic the backend uses), keeping its timezone reading.
export const addMinutesToDateTimeInputValue = (value, minutes, timezone) => {
  const isoValue = fromDateTimeInputValue(value, timezone);
  if (!isoValue) return '';
  return toDateTimeInputValue(
    new Date(new Date(isoValue).getTime() + minutes * 60 * 1000),
    timezone
  );
};

export const dateTimeInputDurationMinutes = (startsAt, endsAt, timezone) => {
  const start = fromDateTimeInputValue(startsAt, timezone);
  const end = fromDateTimeInputValue(endsAt, timezone);
  if (!start || !end) return 0;
  return (new Date(end).getTime() - new Date(start).getTime()) / 60000;
};

// Date and time of an appointment (or a provider command) on the workspace
// clock, e.g. in the MedElement move confirmation.
export const formatSchedulingDateTime = (value, locale, timezone) => {
  if (!value) return '—';
  return formatLocalizedDate(toDate(value), locale, {
    dateStyle: 'medium',
    timeStyle: 'short',
    ...(timezone ? { timeZone: timezone } : {}),
  });
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

export const buildTimeOffIntervals = (
  timeOffs,
  column,
  convertDate = toDate
) => {
  return timeOffs
    .filter(
      item => item.resourceId === null || item.resourceId === column.resourceId
    )
    .map(item => {
      const interval = clipIntervalToDay(
        convertDate(item.startsAt),
        convertDate(item.endsAt),
        column.date
      );

      return interval && { ...interval, title: item.title || undefined };
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

export const buildMedelementProviderCommandParams = ({
  appointment,
  companyCabinetCode,
  operation,
  patch = {},
}) => {
  const params = {
    appointment_id: appointment.id,
    operation,
    provider: 'medelement',
  };

  if (operation === 'remove_reception') return params;

  params.company_cabinet_code = companyCabinetCode;
  if (operation === 'move_reception') {
    params.desired_ends_at = patch.ends_at || appointment.endsAt;
    params.desired_starts_at = patch.starts_at || appointment.startsAt;
  }

  return params;
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

export const isServiceAvailableForResource = (service, resourceId) =>
  (service?.prices || []).some(
    price =>
      Number(price.resourceId) === Number(resourceId) && price.active !== false
  );

const isMedelementService = service => {
  const customAttributes =
    service?.customAttributes || service?.custom_attributes || {};

  return Boolean(
    customAttributes.medelement_nomenclature_code ||
      customAttributes.medelementNomenclatureCode
  );
};

export const servicesAvailableForResource = (services, resource) => {
  const availableServices = services || [];
  if (!isMedelementResource(resource)) return availableServices;

  const medelementServices = availableServices.filter(isMedelementService);
  const linkedServices = medelementServices.filter(service =>
    isServiceAvailableForResource(service, resource?.id)
  );

  return linkedServices.length > 0 ? linkedServices : medelementServices;
};

export const medelementCommandFailureMessage = command => {
  if (command?.lastErrorCode === 'patient_identity_conflict') {
    return { key: 'SCHEDULING.MEDELEMENT.PATIENT_IDENTITY_CONFLICT' };
  }

  if (
    command?.lastErrorCode === 'provider_http_error' &&
    Number(command?.lastErrorStatus) === 401
  ) {
    return { key: 'SCHEDULING.MEDELEMENT.AUTHENTICATION_FAILED' };
  }

  const code = command?.lastErrorCode || command?.status || 'failed';
  const status = Number(command?.lastErrorStatus);

  return {
    key: 'SCHEDULING.MEDELEMENT.FAILED',
    params: {
      code:
        Number.isFinite(status) && status > 0
          ? `${code} (HTTP ${status})`
          : code,
    },
  };
};
