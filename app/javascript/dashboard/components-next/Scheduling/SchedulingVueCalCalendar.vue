<script setup>
import { computed, nextTick, onMounted, ref, toRef, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { VueCal } from 'vue-cal';

import {
  APPOINTMENT_STATUS_ICONS,
  HOUR_ROW_HEIGHT,
  MINUTE_STEP,
} from 'dashboard/routes/dashboard/scheduling/constants';
import { buildCustomFieldSummary } from 'dashboard/stores/crm/customFieldFormatter';
import {
  buildBreakIntervals,
  buildCalendarColumns,
  buildDayListForView,
  clipIntervalToDay,
  buildTimeOffIntervals,
  deriveVisibleMinuteWindow,
  formatDateKey,
  formatTimeLabel,
  minuteOfDayFromDate,
  snapMinute,
  toDate,
} from 'dashboard/routes/dashboard/scheduling/helpers';
import { useSchedulingCalendarIndexes } from 'dashboard/routes/dashboard/scheduling/composables/useSchedulingCalendarIndexes';

const props = defineProps({
  anchorDate: {
    type: [Date, String],
    required: true,
  },
  appointments: {
    type: Array,
    default: () => [],
  },
  breakRules: {
    type: Array,
    default: () => [],
  },
  customFieldDefinitions: {
    type: Array,
    default: () => [],
  },
  holidays: {
    type: Array,
    default: () => [],
  },
  resources: {
    type: Array,
    default: () => [],
  },
  readOnly: {
    type: Boolean,
    default: false,
  },
  createOnly: {
    type: Boolean,
    default: false,
  },
  allowCreateWithoutResources: {
    type: Boolean,
    default: false,
  },
  slots: {
    type: Array,
    default: () => [],
  },
  timeOffs: {
    type: Array,
    default: () => [],
  },
  view: {
    type: String,
    required: true,
  },
  workRules: {
    type: Array,
    default: () => [],
  },
  workdayOverrides: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits([
  'createAppointment',
  'moveAppointment',
  'resizeAppointment',
  'selectAppointment',
]);

const TIMELINE_ROW_HEIGHT_MULTIPLIER = 1.25;
const EVENT_CLICK_SUPPRESSION_MS = 900;
const TIMELINE_HALF_HOUR_STEP_MIN = 30;
const TIMELINE_HOUR_STEP_MIN = 60;

const { t, locale } = useI18n();
const vueCalRef = ref(null);
const isVueCalReady = ref(false);

const localeCode = computed(() => {
  const normalized = locale.value?.replace(/_/g, '-').toLowerCase();
  if (!normalized) {
    return 'en-us';
  }

  if (normalized === 'en') {
    return 'en-us';
  }

  return normalized;
});

const appointmentsRef = toRef(props, 'appointments');
const holidaysRef = toRef(props, 'holidays');
const resourcesRef = toRef(props, 'resources');
const slotsRef = toRef(props, 'slots');
const timeOffsRef = toRef(props, 'timeOffs');

const {
  blockingHolidayForDay,
  buildMonthStats,
  findFirstAvailableSlotForDay,
  slotStepMin,
} = useSchedulingCalendarIndexes({
  appointments: appointmentsRef,
  holidays: holidaysRef,
  resources: resourcesRef,
  slots: slotsRef,
  timeOffs: timeOffsRef,
});

const isTimelineView = computed(() => ['day', 'week'].includes(props.view));
const monthDays = computed(() =>
  buildDayListForView('month', props.anchorDate)
);
const columns = computed(() =>
  buildCalendarColumns(props.view, props.anchorDate, props.resources)
);
const monthStats = computed(() => buildMonthStats(monthDays.value));
const todayDateKey = computed(() => formatDateKey(new Date()));

const resourceById = computed(() => {
  return props.resources.reduce((result, resource) => {
    result[resource.id] = resource;
    return result;
  }, {});
});

const timelineStepMin = computed(() => MINUTE_STEP);
const timelineSlotDurationStepMin = computed(() =>
  Math.max(MINUTE_STEP, slotStepMin.value || MINUTE_STEP)
);

const visibleWindow = computed(() => {
  return deriveVisibleMinuteWindow({
    appointments: props.appointments,
    columns: columns.value,
    workRules: props.workRules,
    workdayOverrides: props.workdayOverrides,
  });
});

const timeCellHeight = computed(() => {
  return (
    HOUR_ROW_HEIGHT *
    TIMELINE_ROW_HEIGHT_MULTIPLIER *
    (timelineStepMin.value / 60)
  );
});

const minutePixelSize = computed(() => {
  return timeCellHeight.value / timelineStepMin.value;
});

const isWeekSharedTimeline = computed(() => props.view === 'week');
const hasWeekSecondaryLabels = computed(
  () => props.view === 'week' && props.resources.length > 0
);
const isSingleLineWeekHeader = computed(
  () => props.view === 'week' && !hasWeekSecondaryLabels.value
);
const timelineHalfHourGridSize = computed(() => {
  return `${minutePixelSize.value * TIMELINE_HALF_HOUR_STEP_MIN}px`;
});
const timelineHourGridSize = computed(() => {
  return `${minutePixelSize.value * TIMELINE_HOUR_STEP_MIN}px`;
});
const timelineHalfHourGridOffset = computed(() => {
  const offsetMinute =
    visibleWindow.value.startMinute % TIMELINE_HALF_HOUR_STEP_MIN;
  return `${-minutePixelSize.value * offsetMinute}px`;
});
const timelineHourGridOffset = computed(() => {
  const offsetMinute = visibleWindow.value.startMinute % TIMELINE_HOUR_STEP_MIN;
  return `${-minutePixelSize.value * offsetMinute}px`;
});
const weekdayBarSize = computed(() => {
  if (props.view !== 'week') {
    return undefined;
  }

  return hasWeekSecondaryLabels.value ? '2.05rem' : '1.35rem';
});

const calendarCssVars = computed(() => ({
  '--scheduling-half-hour-grid-offset': timelineHalfHourGridOffset.value,
  '--scheduling-half-hour-grid-size': timelineHalfHourGridSize.value,
  '--scheduling-hour-grid-offset': timelineHourGridOffset.value,
  '--scheduling-hour-grid-size': timelineHourGridSize.value,
  '--scheduling-weekday-bar-size': weekdayBarSize.value,
  '--vuecal-min-schedule-size': '0px',
}));

const mergeIntervals = intervals => {
  return intervals
    .slice()
    .sort((left, right) => left.startMinute - right.startMinute)
    .reduce((result, interval) => {
      const lastInterval = result[result.length - 1];

      if (!lastInterval) {
        result.push({ ...interval });
        return result;
      }

      if (interval.startMinute <= lastInterval.endMinute) {
        lastInterval.endMinute = Math.max(
          lastInterval.endMinute,
          interval.endMinute
        );
        return result;
      }

      result.push({ ...interval });
      return result;
    }, []);
};

const mergeLabeledIntervals = intervals => {
  return intervals
    .filter(Boolean)
    .slice()
    .sort((left, right) => left.startMinute - right.startMinute)
    .reduce((result, interval) => {
      const labels = new Set(
        [interval.label].flat().filter(value => String(value || '').trim())
      );
      const lastInterval = result[result.length - 1];

      if (!lastInterval) {
        result.push({
          startMinute: interval.startMinute,
          endMinute: interval.endMinute,
          labels,
        });
        return result;
      }

      if (interval.startMinute <= lastInterval.endMinute) {
        lastInterval.endMinute = Math.max(
          lastInterval.endMinute,
          interval.endMinute
        );
        labels.forEach(label => lastInterval.labels.add(label));
        return result;
      }

      result.push({
        startMinute: interval.startMinute,
        endMinute: interval.endMinute,
        labels,
      });
      return result;
    }, [])
    .map(interval => ({
      ...interval,
      label: Array.from(interval.labels).join(', '),
    }));
};

const subtractIntervals = (baseIntervals, blockedIntervals) => {
  const normalizedBlocked = mergeIntervals(
    blockedIntervals.filter(
      interval =>
        interval &&
        Number.isFinite(interval.startMinute) &&
        Number.isFinite(interval.endMinute) &&
        interval.endMinute > interval.startMinute
    )
  );

  return baseIntervals.flatMap(interval => {
    if (
      !interval ||
      !Number.isFinite(interval.startMinute) ||
      !Number.isFinite(interval.endMinute) ||
      interval.endMinute <= interval.startMinute
    ) {
      return [];
    }

    return normalizedBlocked.reduce(
      (segments, blockedInterval) => {
        return segments.flatMap(segment => {
          if (
            blockedInterval.endMinute <= segment.startMinute ||
            blockedInterval.startMinute >= segment.endMinute
          ) {
            return [segment];
          }

          const nextSegments = [];

          if (blockedInterval.startMinute > segment.startMinute) {
            nextSegments.push({
              startMinute: segment.startMinute,
              endMinute: Math.min(
                blockedInterval.startMinute,
                segment.endMinute
              ),
            });
          }

          if (blockedInterval.endMinute < segment.endMinute) {
            nextSegments.push({
              startMinute: Math.max(
                blockedInterval.endMinute,
                segment.startMinute
              ),
              endMinute: segment.endMinute,
            });
          }

          return nextSegments;
        });
      },
      [interval]
    );
  });
};

const buildWorkingIntervalsForColumn = column => {
  const override = props.workdayOverrides.find(item => {
    return (
      Number(item.resourceId) === Number(column.resourceId) &&
      item.date === column.dateKey
    );
  });

  if (override) {
    if (
      override.startMinute === null ||
      override.startMinute === undefined ||
      override.endMinute === null ||
      override.endMinute === undefined ||
      override.endMinute <= override.startMinute
    ) {
      return [];
    }

    return [
      {
        startMinute: override.startMinute,
        endMinute: override.endMinute,
      },
    ];
  }

  return props.workRules
    .filter(rule => {
      return (
        Number(rule.resourceId) === Number(column.resourceId) &&
        rule.weekday === column.date.getDay() &&
        rule.active
      );
    })
    .map(rule => ({
      startMinute: rule.startMinute,
      endMinute: rule.endMinute,
    }))
    .filter(interval => interval.endMinute > interval.startMinute);
};

const buildAppointmentIntervalsForColumn = (
  column,
  { excludeAppointmentId = null } = {}
) => {
  return props.appointments
    .filter(appointment => {
      return (
        Number(appointment.resourceId) === Number(column.resourceId) &&
        Number(appointment.id) !== Number(excludeAppointmentId) &&
        appointment.status !== 'cancelled'
      );
    })
    .map(appointment => {
      return clipIntervalToDay(
        toDate(appointment.startsAt),
        toDate(appointment.endsAt),
        column.date
      );
    })
    .filter(Boolean);
};

const buildCreatableIntervalsForColumn = (
  column,
  { excludeAppointmentId = null } = {}
) => {
  return subtractIntervals(buildWorkingIntervalsForColumn(column), [
    ...buildBreakIntervals(props.breakRules, props.workdayOverrides, column),
    ...buildTimeOffIntervals(props.timeOffs, column),
    ...buildAppointmentIntervalsForColumn(column, { excludeAppointmentId }),
  ]);
};

const buildAvailabilityDisplayIntervalsForColumn = column => {
  return subtractIntervals(buildWorkingIntervalsForColumn(column), [
    ...buildBreakIntervals(props.breakRules, props.workdayOverrides, column),
    ...buildTimeOffIntervals(props.timeOffs, column),
  ]);
};

const resolveFullDayBackgroundKindForColumn = column => {
  if (blockingHolidayForDay(column.date)) {
    return 'holiday';
  }

  const workingIntervals = buildWorkingIntervalsForColumn(column);
  if (!workingIntervals.length) {
    return 'closed';
  }

  const displayAvailabilityIntervals =
    buildAvailabilityDisplayIntervalsForColumn(column);
  if (displayAvailabilityIntervals.length) {
    return null;
  }

  const timeOffIntervals = buildTimeOffIntervals(props.timeOffs, column);
  const isDayOff =
    timeOffIntervals.length &&
    subtractIntervals(workingIntervals, timeOffIntervals).length === 0;

  return isDayOff ? 'day-off' : 'closed';
};

const resolveFullDayBackgroundKindForDay = day => {
  if (blockingHolidayForDay(day)) {
    return 'holiday';
  }

  if (!props.resources.length) {
    return null;
  }

  const dayColumns = columns.value.filter(column => {
    return column.dateKey === formatDateKey(day);
  });

  if (!dayColumns.length) {
    return 'closed';
  }

  const hasAnyWorkingIntervals = dayColumns.some(column => {
    return buildWorkingIntervalsForColumn(column).length > 0;
  });

  if (!hasAnyWorkingIntervals) {
    return 'closed';
  }

  const displayAvailabilityIntervals = mergeIntervals(
    dayColumns.flatMap(column =>
      buildAvailabilityDisplayIntervalsForColumn(column)
    )
  );

  if (displayAvailabilityIntervals.length) {
    return null;
  }

  const isDayOff = dayColumns.every(column => {
    const workingIntervals = buildWorkingIntervalsForColumn(column);
    if (!workingIntervals.length) {
      return false;
    }

    const timeOffIntervals = buildTimeOffIntervals(props.timeOffs, column);
    return (
      timeOffIntervals.length &&
      subtractIntervals(workingIntervals, timeOffIntervals).length === 0
    );
  });

  return isDayOff ? 'day-off' : 'closed';
};

const visibleResourceIds = computed(() =>
  props.resources
    .map(resource => Number(resource.id))
    .filter(resourceId => Number.isFinite(resourceId) && resourceId > 0)
);

const preferredResourceIdsForCell = cell => {
  const scheduleResourceId = Number(cell?.schedule);

  if (Number.isFinite(scheduleResourceId) && scheduleResourceId > 0) {
    return [scheduleResourceId];
  }

  return visibleResourceIds.value;
};

const rangeFitsIntervals = ({ startsAt, endsAt, intervals }) => {
  if (
    Number.isNaN(startsAt.getTime()) ||
    Number.isNaN(endsAt.getTime()) ||
    endsAt <= startsAt ||
    formatDateKey(startsAt) !== formatDateKey(endsAt)
  ) {
    return false;
  }

  const startMinute = minuteOfDayFromDate(startsAt);
  const endMinute = minuteOfDayFromDate(endsAt);

  return intervals.some(interval => {
    return (
      interval.startMinute <= startMinute && interval.endMinute >= endMinute
    );
  });
};

const canCreateTimelineRangeForResource = ({
  resourceId,
  startsAt,
  endsAt,
  excludeAppointmentId = null,
}) => {
  const dateKey = formatDateKey(startsAt);
  const column = columns.value.find(item => {
    return (
      Number(item.resourceId) === Number(resourceId) && item.dateKey === dateKey
    );
  });

  if (!column || blockingHolidayForDay(column.date)) {
    return false;
  }

  return rangeFitsIntervals({
    startsAt,
    endsAt,
    intervals: buildCreatableIntervalsForColumn(column, {
      excludeAppointmentId,
    }),
  });
};

const findCreatableResourceForRange = ({
  startsAt,
  endsAt,
  preferredResourceIds = [],
} = {}) => {
  const orderedPreferredIds = preferredResourceIds.length
    ? preferredResourceIds
        .map(Number)
        .filter(resourceId => Number.isFinite(resourceId) && resourceId > 0)
    : visibleResourceIds.value;

  if (!orderedPreferredIds.length) {
    return null;
  }

  return (
    orderedPreferredIds.find(resourceId =>
      canCreateTimelineRangeForResource({
        resourceId,
        startsAt,
        endsAt,
      })
    ) || null
  );
};

const weekDays = computed(() =>
  isWeekSharedTimeline.value
    ? buildDayListForView('week', props.anchorDate)
    : []
);
const timelineIncludesToday = computed(() => {
  if (!isTimelineView.value) {
    return false;
  }

  const todayKey = todayDateKey.value;

  if (props.view === 'day') {
    return formatDateKey(props.anchorDate) === todayKey;
  }

  return weekDays.value.some(day => formatDateKey(day) === todayKey);
});

const schedules = computed(() => {
  if (isWeekSharedTimeline.value) {
    return [];
  }

  return props.resources.map(resource => ({
    id: resource.id,
    label: resource.name,
  }));
});

const formatResourceCountLabel = count => {
  if (!count) {
    return '';
  }

  if (localeCode.value.startsWith('ru')) {
    const mod10 = count % 10;
    const mod100 = count % 100;
    let suffix = 'специалистов';

    if (mod10 === 1 && mod100 !== 11) {
      suffix = 'специалист';
    } else if (mod10 >= 2 && mod10 <= 4 && !(mod100 >= 12 && mod100 <= 14)) {
      suffix = 'специалиста';
    }

    return `${count} ${suffix}`;
  }

  return `${count} ${count === 1 ? 'specialist' : 'specialists'}`;
};

const weekDayEmployeeLabelByDateKey = computed(() => {
  if (!isWeekSharedTimeline.value) {
    return new Map();
  }

  const visibleResourceCount = new Set(
    props.resources
      .map(resource => Number(resource.id))
      .filter(resourceId => Number.isFinite(resourceId) && resourceId > 0)
  ).size;
  const resourceCountLabel = formatResourceCountLabel(visibleResourceCount);

  return weekDays.value.reduce((result, day) => {
    result.set(formatDateKey(day), resourceCountLabel);
    return result;
  }, new Map());
});

const normalizeDurationMinForResource = resourceId => {
  const resourceDurationMin = Number(
    resourceById.value[resourceId]?.slotDurationMin
  );

  return Math.max(
    timelineSlotDurationStepMin.value,
    resourceDurationMin || timelineSlotDurationStepMin.value
  );
};

const buildTimelinePayloadForStart = ({
  preferredResourceIds = [],
  startsAt,
} = {}) => {
  const orderedPreferredIds = preferredResourceIds
    .map(Number)
    .filter(resourceId => Number.isFinite(resourceId) && resourceId > 0);

  return (
    orderedPreferredIds
      .map(resourceId => {
        const endsAt = new Date(startsAt);
        endsAt.setMinutes(
          endsAt.getMinutes() + normalizeDurationMinForResource(resourceId)
        );

        if (
          !canCreateTimelineRangeForResource({
            resourceId,
            startsAt,
            endsAt,
          })
        ) {
          return null;
        }

        return {
          endsAt: endsAt.toISOString(),
          resourceId,
          startsAt: startsAt.toISOString(),
        };
      })
      .find(Boolean) || null
  );
};

const buildUnavailableIntervals = intervals => {
  return subtractIntervals(
    [
      {
        startMinute: visibleWindow.value.startMinute,
        endMinute: visibleWindow.value.endMinute,
      },
    ],
    mergeIntervals(intervals)
  );
};

const unavailableBackgroundEvents = computed(() => {
  if (!isTimelineView.value || !props.resources.length) {
    return [];
  }

  if (isWeekSharedTimeline.value) {
    return weekDays.value.flatMap(day => {
      if (resolveFullDayBackgroundKindForDay(day)) {
        return [];
      }

      const dateKey = formatDateKey(day);
      const intervals = buildUnavailableIntervals(
        columns.value
          .filter(column => column.dateKey === dateKey)
          .flatMap(column => buildAvailabilityDisplayIntervalsForColumn(column))
      );

      return intervals.map(interval => {
        const start = new Date(day);
        start.setHours(0, 0, 0, 0);
        start.setMinutes(interval.startMinute, 0, 0);

        const end = new Date(day);
        end.setHours(0, 0, 0, 0);
        end.setMinutes(interval.endMinute, 0, 0);

        return {
          id: `unavailable-week-${dateKey}-${interval.startMinute}`,
          start,
          end,
          background: true,
          backgroundKind: 'unavailable',
          class:
            'scheduling-vue-cal__background-event scheduling-vue-cal__background-event--unavailable',
        };
      });
    });
  }

  return columns.value.flatMap(column => {
    if (resolveFullDayBackgroundKindForColumn(column)) {
      return [];
    }

    const intervals = buildUnavailableIntervals(
      buildAvailabilityDisplayIntervalsForColumn(column)
    );

    return intervals.map(interval => {
      const start = new Date(column.date);
      start.setHours(0, 0, 0, 0);
      start.setMinutes(interval.startMinute, 0, 0);

      const end = new Date(column.date);
      end.setHours(0, 0, 0, 0);
      end.setMinutes(interval.endMinute, 0, 0);

      return {
        id: `unavailable-${column.resourceId}-${column.dateKey}-${interval.startMinute}`,
        start,
        end,
        schedule: column.resourceId,
        background: true,
        backgroundKind: 'unavailable',
        class:
          'scheduling-vue-cal__background-event scheduling-vue-cal__background-event--unavailable',
      };
    });
  });
});

const timelineBackgroundEvents = computed(() => {
  if (!isTimelineView.value) {
    return [];
  }

  if (isWeekSharedTimeline.value) {
    return weekDays.value.flatMap(day => {
      const events = [];
      const dateKey = formatDateKey(day);
      const fullDayKind = resolveFullDayBackgroundKindForDay(day);
      const holiday = blockingHolidayForDay(day);

      if (fullDayKind) {
        const start = new Date(day);
        start.setHours(0, 0, 0, 0);
        const end = new Date(start);
        end.setDate(end.getDate() + 1);

        events.push({
          id: `${fullDayKind}-week-${dateKey}`,
          start,
          end,
          background: true,
          backgroundKind: fullDayKind,
          backgroundLabel: holiday?.title || '',
          class: `scheduling-vue-cal__background-event scheduling-vue-cal__background-event--${fullDayKind}`,
        });

        if (fullDayKind === 'holiday') {
          return events;
        }
      }

      const dayColumns = columns.value.filter(
        column => column.dateKey === dateKey
      );
      const breakIntervals = mergeLabeledIntervals(
        dayColumns.flatMap(column =>
          buildBreakIntervals(
            props.breakRules,
            props.workdayOverrides,
            column
          ).map(interval => ({
            startMinute: interval.startMinute,
            endMinute: interval.endMinute,
            label: interval.title || '',
          }))
        )
      );
      const timeOffIntervals = mergeLabeledIntervals(
        dayColumns.flatMap(column =>
          buildTimeOffIntervals(props.timeOffs, column).map(interval => ({
            startMinute: interval.startMinute,
            endMinute: interval.endMinute,
            label: interval.title || '',
          }))
        )
      );

      breakIntervals.forEach(interval => {
        const start = new Date(day);
        start.setHours(0, 0, 0, 0);
        start.setMinutes(interval.startMinute, 0, 0);

        const end = new Date(day);
        end.setHours(0, 0, 0, 0);
        end.setMinutes(interval.endMinute, 0, 0);

        events.push({
          id: `break-week-${dateKey}-${interval.startMinute}`,
          start,
          end,
          background: true,
          backgroundKind: 'break',
          backgroundLabel: interval.label || '',
          class:
            'scheduling-vue-cal__background-event scheduling-vue-cal__background-event--break',
        });
      });

      timeOffIntervals.forEach(interval => {
        const start = new Date(day);
        start.setHours(0, 0, 0, 0);
        start.setMinutes(interval.startMinute, 0, 0);

        const end = new Date(day);
        end.setHours(0, 0, 0, 0);
        end.setMinutes(interval.endMinute, 0, 0);

        events.push({
          id: `timeoff-week-${dateKey}-${interval.startMinute}`,
          start,
          end,
          background: true,
          backgroundKind: 'time-off',
          backgroundLabel: interval.label || '',
          class:
            'scheduling-vue-cal__background-event scheduling-vue-cal__background-event--time-off',
        });
      });

      return events;
    });
  }

  return columns.value.flatMap(column => {
    const events = [];
    const fullDayKind = resolveFullDayBackgroundKindForColumn(column);
    const holiday = blockingHolidayForDay(column.date);

    if (fullDayKind) {
      const start = new Date(column.date);
      start.setHours(0, 0, 0, 0);
      const end = new Date(start);
      end.setDate(end.getDate() + 1);

      events.push({
        id: `${fullDayKind}-${column.resourceId}-${column.dateKey}`,
        start,
        end,
        schedule: column.resourceId,
        background: true,
        backgroundKind: fullDayKind,
        backgroundLabel: holiday?.title || '',
        class: `scheduling-vue-cal__background-event scheduling-vue-cal__background-event--${fullDayKind}`,
      });

      if (fullDayKind === 'holiday') {
        return events;
      }
    }

    buildBreakIntervals(
      props.breakRules,
      props.workdayOverrides,
      column
    ).forEach(interval => {
      const start = new Date(column.date);
      start.setHours(0, 0, 0, 0);
      start.setMinutes(interval.startMinute, 0, 0);

      const end = new Date(column.date);
      end.setHours(0, 0, 0, 0);
      end.setMinutes(interval.endMinute, 0, 0);

      events.push({
        id: `break-${column.resourceId}-${column.dateKey}-${interval.startMinute}`,
        start,
        end,
        schedule: column.resourceId,
        background: true,
        backgroundKind: 'break',
        backgroundLabel: interval.title || '',
        class:
          'scheduling-vue-cal__background-event scheduling-vue-cal__background-event--break',
      });
    });

    buildTimeOffIntervals(props.timeOffs, column).forEach(interval => {
      const start = new Date(column.date);
      start.setHours(0, 0, 0, 0);
      start.setMinutes(interval.startMinute, 0, 0);

      const end = new Date(column.date);
      end.setHours(0, 0, 0, 0);
      end.setMinutes(interval.endMinute, 0, 0);

      events.push({
        id: `timeoff-${column.resourceId}-${column.dateKey}-${interval.startMinute}`,
        start,
        end,
        schedule: column.resourceId,
        background: true,
        backgroundKind: 'time-off',
        class:
          'scheduling-vue-cal__background-event scheduling-vue-cal__background-event--time-off',
      });
    });

    return events;
  });
});

const appointmentEvents = computed(() => {
  return props.appointments.map(appointment => {
    const resource = resourceById.value[appointment.resourceId];
    const clientName = appointment.title || appointment.clientName || '—';
    const subtitle = [
      appointment.serviceNameSnapshot || appointment.subtitle,
      appointment.resourceName || resource?.name,
    ]
      .filter(Boolean)
      .join(' · ');
    const resourceColor =
      appointment.resourceColor || resource?.color || '#2563eb';
    const resourceName = appointment.resourceName || resource?.name || '';

    return {
      id: String(appointment.id),
      start: toDate(appointment.startsAt),
      end: toDate(appointment.endsAt),
      title: clientName,
      schedule:
        isWeekSharedTimeline.value || !props.resources.length
          ? null
          : appointment.resourceId,
      appointment,
      status: appointment.status,
      statusIcon: appointment.statusIcon || '',
      statusLabel: appointment.statusLabel || '',
      paymentStatus: appointment.paymentStatus,
      clientName,
      serviceNameSnapshot: subtitle,
      resourceColor,
      resourceName,
      muted: Boolean(appointment.muted),
      cancelled: Boolean(appointment.cancelled),
      durationMin: appointment.durationMin,
      class: `scheduling-vue-cal__appointment scheduling-vue-cal__appointment--${appointment.status || 'scheduled'}`,
    };
  });
});

const calendarEvents = computed(() => {
  return [
    ...unavailableBackgroundEvents.value,
    ...timelineBackgroundEvents.value,
    ...appointmentEvents.value,
  ];
});

let suppressEventSelectionUntil = 0;

const suppressEventSelection = (durationMs = EVENT_CLICK_SUPPRESSION_MS) => {
  suppressEventSelectionUntil = Date.now() + durationMs;
};

const supportsUnscheduledCreate = computed(
  () => props.allowCreateWithoutResources && !props.resources.length
);

const editableEvents = computed(() => {
  if (props.readOnly) {
    return {
      create: false,
      delete: false,
      drag: false,
      resize: false,
    };
  }

  if (!isTimelineView.value) {
    return {
      create: false,
      delete: false,
      drag: false,
      resize: false,
    };
  }

  if (props.createOnly) {
    return {
      create: true,
      delete: false,
      drag: false,
      resize: false,
    };
  }

  return {
    create: true,
    delete: false,
    drag: true,
    resize: true,
  };
});

const isWeeklyScheduleHeading = computed(() => props.view === 'week');

const appointmentStatusLabel = status => {
  const labels = {
    cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
    completed: t('SCHEDULING.APPOINTMENT_STATUS.completed'),
    confirmed: t('SCHEDULING.APPOINTMENT_STATUS.confirmed'),
    no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
    scheduled: t('SCHEDULING.APPOINTMENT_STATUS.scheduled'),
  };

  return labels[status] || labels.scheduled;
};

const appointmentStatusIcon = status =>
  APPOINTMENT_STATUS_ICONS[status] || APPOINTMENT_STATUS_ICONS.scheduled;

const resolveEventStatusLabel = event =>
  event.statusLabel || appointmentStatusLabel(event.status);

const resolveEventStatusIcon = event =>
  event.statusIcon || appointmentStatusIcon(event.status);

const isMutedAppointmentCard = event =>
  event.muted || ['completed', 'no_show'].includes(event.status);

const isCancelledAppointmentCard = event =>
  event.cancelled || event.status === 'cancelled';

const isUnavailableBackgroundKind = backgroundKind => {
  return [
    'unavailable',
    'closed',
    'day-off',
    'holiday',
    'break',
    'time-off',
  ].includes(backgroundKind);
};

const formatEventTimeRange = event => {
  return `${formatTimeLabel(minuteOfDayFromDate(event.start))}-${formatTimeLabel(minuteOfDayFromDate(event.end))}`;
};

const customFieldSummaryTitle = appointment => {
  return buildCustomFieldSummary(
    props.customFieldDefinitions,
    appointment?.customAttributes,
    {
      locale: localeCode.value,
      maxItems: 2,
      noLabel: t('CHOICE_TOGGLE.NO'),
      yesLabel: t('CHOICE_TOGGLE.YES'),
    }
  )
    .map(entry => `${entry.label}: ${entry.displayValue}`)
    .join(' · ');
};

const eventTitle = event => {
  return [
    formatEventTimeRange(event),
    resolveEventStatusLabel(event),
    event.resourceName,
    event.clientName,
    customFieldSummaryTitle(event.appointment),
  ]
    .filter(Boolean)
    .join(' · ');
};

const formatScheduleHeadingLabel = schedule => {
  const rawLabel = String(
    resourceById.value[schedule.id]?.name || schedule.label || ''
  ).trim();

  if (!isWeeklyScheduleHeading.value) {
    return rawLabel || '—';
  }

  const parts = rawLabel.split(/\s+/).filter(Boolean);

  if (!parts.length) {
    return '—';
  }

  const initials =
    parts.length >= 2
      ? parts
          .slice(0, 2)
          .map(part => Array.from(part)[0] || '')
          .join('')
      : Array.from(parts[0]).slice(0, 2).join('');

  return initials.toLocaleUpperCase(localeCode.value);
};

const formatScheduleHeadingAbbreviation = schedule => {
  const initials = formatScheduleHeadingLabel(schedule);

  if (!isWeeklyScheduleHeading.value || initials === '—') {
    return initials;
  }

  return Array.from(initials)
    .filter(Boolean)
    .map(char => `${char}.`)
    .join('');
};

const formatMonthSlotMeta = day => {
  const stats = monthStats.value.get(formatDateKey(day));
  if (!stats?.availableSlots) {
    return '';
  }

  return t('SCHEDULING.CALENDAR.AVAILABLE_SLOTS', {
    count: stats.availableSlots,
  });
};

const defaultCreatePayload = day => {
  if (props.slots.length && blockingHolidayForDay(day)) {
    return null;
  }

  const firstAvailableSlot = findFirstAvailableSlotForDay({
    day,
    preferredResourceIds: props.resources.map(resource => resource.id),
  });

  if (firstAvailableSlot) {
    return {
      endsAt: firstAvailableSlot.endsAt,
      resourceId: firstAvailableSlot.resourceId,
      startsAt: firstAvailableSlot.startsAt,
    };
  }

  if (props.slots.length) {
    return null;
  }

  const startsAt = new Date(day);
  startsAt.setHours(9, 0, 0, 0);

  const defaultDuration =
    Number(props.resources[0]?.slotDurationMin) || timelineStepMin.value;
  const endsAt = new Date(startsAt);
  endsAt.setMinutes(endsAt.getMinutes() + defaultDuration);

  return {
    endsAt: endsAt.toISOString(),
    resourceId: props.resources[0]?.id || '',
    startsAt: startsAt.toISOString(),
  };
};

const unavailableSlotMessage = () => {
  useAlert(t('SCHEDULING.CALENDAR.UNAVAILABLE_SLOT'));
};

const buildUnscheduledCreatePayload = ({ startsAt, endsAt }) => ({
  endsAt: endsAt.toISOString(),
  startsAt: startsAt.toISOString(),
});

const buildTimelineCreateRangeFromCursor = ({ cell, cursor }) => {
  if (!cursor?.date) {
    return null;
  }

  const startsAt = new Date(cell.start);
  startsAt.setHours(0, 0, 0, 0);
  startsAt.setMinutes(
    snapMinute(minuteOfDayFromDate(cursor.date), timelineStepMin.value),
    0,
    0
  );

  const endsAt = new Date(startsAt);
  endsAt.setMinutes(
    endsAt.getMinutes() + Math.max(timelineSlotDurationStepMin.value, 60)
  );

  return { endsAt, startsAt };
};

const resolveClickedResourceId = ({ cell, e }) => {
  const rawSchedule =
    cell?.schedule ||
    e?.target?.closest?.('[data-schedule]')?.dataset?.schedule;
  const resourceId = Number(rawSchedule);

  return Number.isFinite(resourceId) && resourceId > 0 ? resourceId : null;
};

const buildTimelineClickPayload = ({ cell, cursor, e }) => {
  const timelineRange = buildTimelineCreateRangeFromCursor({ cell, cursor });
  if (!timelineRange) {
    return null;
  }

  if (supportsUnscheduledCreate.value) {
    return buildUnscheduledCreatePayload(timelineRange);
  }

  const clickedResourceId = resolveClickedResourceId({ cell, e });
  const preferredResourceIds = clickedResourceId
    ? [clickedResourceId]
    : preferredResourceIdsForCell(cell);
  return buildTimelinePayloadForStart({
    preferredResourceIds,
    startsAt: timelineRange.startsAt,
  });
};

const handleCellClick = payload => {
  if (props.readOnly) {
    return;
  }

  if (Date.now() < suppressEventSelectionUntil) {
    return;
  }

  if (props.view === 'month') {
    const monthPayload = defaultCreatePayload(payload.cell.start);
    if (!monthPayload) {
      unavailableSlotMessage();
      return;
    }

    emit('createAppointment', monthPayload);
    return;
  }

  if (!isTimelineView.value) {
    return;
  }

  const timelinePayload = buildTimelineClickPayload(payload);
  if (!timelinePayload) {
    return;
  }

  emit('createAppointment', timelinePayload);
};

const handleEventCreate = ({ event, resolve }) => {
  if (props.readOnly) {
    resolve(false);
    return;
  }

  const startsAt = new Date(event.start);
  const endsAt = new Date(event.end);

  if (supportsUnscheduledCreate.value) {
    emit(
      'createAppointment',
      buildUnscheduledCreatePayload({ endsAt, startsAt })
    );
    resolve(false);
    return;
  }

  const resourceId = findCreatableResourceForRange({
    startsAt,
    endsAt,
    preferredResourceIds: preferredResourceIdsForCell({
      schedule: event.schedule,
    }),
  });

  if (
    !resourceId ||
    !canCreateTimelineRangeForResource({ resourceId, startsAt, endsAt })
  ) {
    unavailableSlotMessage();
    resolve(false);
    return;
  }

  emit('createAppointment', {
    endsAt: endsAt.toISOString(),
    resourceId,
    startsAt: startsAt.toISOString(),
  });
  resolve(false);
};

const handleEventDrop = ({ event }) => {
  if (props.readOnly || props.createOnly) {
    return false;
  }

  suppressEventSelection();

  const appointment = event.appointment;
  const startsAt = new Date(event.start);
  const endsAt = new Date(event.end);

  if (supportsUnscheduledCreate.value) {
    if (!appointment) {
      unavailableSlotMessage();
      return false;
    }

    emit('moveAppointment', {
      appointment,
      endsAt: endsAt.toISOString(),
      startsAt: startsAt.toISOString(),
    });

    return true;
  }

  const resourceId = Number(event.schedule || appointment?.resourceId);

  if (
    !appointment ||
    !resourceId ||
    !canCreateTimelineRangeForResource({
      resourceId,
      startsAt,
      endsAt,
      excludeAppointmentId: appointment.id,
    })
  ) {
    unavailableSlotMessage();
    return false;
  }

  emit('moveAppointment', {
    appointment,
    endsAt: endsAt.toISOString(),
    resourceId,
    startsAt: startsAt.toISOString(),
  });

  return true;
};

const handleEventResizeEnd = ({ event }) => {
  if (props.readOnly || props.createOnly) {
    return false;
  }

  suppressEventSelection();

  const appointment = event.appointment;
  const startsAt = new Date(event.start);
  const endsAt = new Date(event.end);

  if (supportsUnscheduledCreate.value) {
    if (!appointment) {
      unavailableSlotMessage();
      return false;
    }

    emit('resizeAppointment', {
      appointment,
      endsAt: endsAt.toISOString(),
      startsAt: startsAt.toISOString(),
    });

    return true;
  }

  if (
    !appointment ||
    !canCreateTimelineRangeForResource({
      resourceId: appointment.resourceId,
      startsAt,
      endsAt,
      excludeAppointmentId: appointment.id,
    })
  ) {
    unavailableSlotMessage();
    return false;
  }

  emit('resizeAppointment', {
    appointment,
    endsAt: endsAt.toISOString(),
    startsAt: startsAt.toISOString(),
  });

  return true;
};

const handleEventDragStart = () => {
  suppressEventSelection();
};

const handleEventResizeStart = () => {
  suppressEventSelection();
};

const handleEventClick = ({ event, e }) => {
  if (event.background) {
    return;
  }

  if (e?.target?.closest?.('.vuecal__event-resizer')) {
    return;
  }

  if (Date.now() < suppressEventSelectionUntil) {
    return;
  }

  emit('selectAppointment', event.appointment);
};

const autoScrollTimeline = async () => {
  if (!isTimelineView.value || !isVueCalReady.value) {
    return;
  }

  await nextTick();

  const viewApi = vueCalRef.value?.view;
  if (!viewApi) {
    return;
  }

  if (timelineIncludesToday.value && viewApi.scrollToCurrentTime) {
    viewApi.scrollToCurrentTime();
    return;
  }

  viewApi.scrollToTime?.(visibleWindow.value.startMinute);
};

const handleCalendarReady = () => {
  isVueCalReady.value = true;
  autoScrollTimeline();
};

watch(
  [
    () => props.view,
    () => props.anchorDate,
    () => visibleWindow.value.startMinute,
    () => visibleWindow.value.endMinute,
  ],
  autoScrollTimeline,
  {
    flush: 'post',
  }
);

onMounted(() => {
  autoScrollTimeline();
});
</script>

<template>
  <div
    class="scheduling-vue-cal rounded-lg bg-n-solid-2 outline outline-1 outline-n-container"
    :class="{
      'scheduling-vue-cal--day': view === 'day',
      'scheduling-vue-cal--week-single-line': isSingleLineWeekHeader,
      'scheduling-vue-cal--week': view === 'week',
    }"
    :style="calendarCssVars"
  >
    <div class="scheduling-vue-cal__viewport">
      <div class="scheduling-vue-cal__frame">
        <VueCal
          ref="vueCalRef"
          class="scheduling-vue-cal__calendar bg-transparent"
          :locale="localeCode"
          :events="calendarEvents"
          :schedules="schedules"
          :editable-events="editableEvents"
          events-on-month-view
          :snap-to-interval="timelineStepMin"
          :time="view !== 'month'"
          :watch-real-time="isTimelineView"
          :time-cell-height="timeCellHeight"
          :time-from="visibleWindow.startMinute"
          :time-step="timelineStepMin"
          :time-to="visibleWindow.endMinute"
          :title-bar="false"
          :today-button="false"
          :views="[view]"
          :view="view"
          :view-date="anchorDate"
          :views-bar="false"
          @cell-click="handleCellClick"
          @event-create="handleEventCreate"
          @event-delayed-click="handleEventClick"
          @event-drag-start="handleEventDragStart"
          @event-drop="handleEventDrop"
          @event-resize-start="handleEventResizeStart"
          @event-resize-end="handleEventResizeEnd"
          @ready="handleCalendarReady"
        >
          <template #weekday-heading="{ label, date }">
            <div class="scheduling-vue-cal__weekday-heading">
              <div class="scheduling-vue-cal__weekday-primary">
                <span class="scheduling-vue-cal__weekday-text">{{
                  label
                }}</span>
                <span class="scheduling-vue-cal__weekday-text">
                  {{ date.getDate() }}
                </span>
                <span
                  v-if="view === 'week' && blockingHolidayForDay(date)"
                  class="scheduling-vue-cal__weekday-holiday-dot"
                />
              </div>
              <div
                v-if="
                  view === 'week' &&
                  weekDayEmployeeLabelByDateKey.get(formatDateKey(date))
                "
                class="scheduling-vue-cal__weekday-secondary"
              >
                {{ weekDayEmployeeLabelByDateKey.get(formatDateKey(date)) }}
              </div>
            </div>
          </template>

          <template #schedule-heading="{ schedule }">
            <div
              class="scheduling-vue-cal__schedule-heading"
              :style="{
                '--schedule-accent':
                  resourceById[schedule.id]?.color || '#2563eb',
              }"
            >
              <div
                class="scheduling-vue-cal__schedule-chip"
                :class="{
                  'scheduling-vue-cal__schedule-chip--week':
                    isWeeklyScheduleHeading,
                }"
              >
                <span
                  class="scheduling-vue-cal__schedule-dot"
                  :style="{
                    backgroundColor:
                      resourceById[schedule.id]?.color || '#2563eb',
                  }"
                />
                <div
                  class="scheduling-vue-cal__schedule-label"
                  :class="{
                    'scheduling-vue-cal__schedule-label--week':
                      isWeeklyScheduleHeading,
                  }"
                >
                  {{
                    isWeeklyScheduleHeading
                      ? formatScheduleHeadingAbbreviation(schedule)
                      : formatScheduleHeadingLabel(schedule)
                  }}
                </div>
              </div>
            </div>
          </template>

          <template #time-cell="{ minutesSum, format24 }">
            <label
              class="scheduling-vue-cal__time-label"
              :class="{
                'scheduling-vue-cal__time-label--hour': minutesSum % 60 === 0,
                'scheduling-vue-cal__time-label--muted': minutesSum % 30 !== 0,
                'scheduling-vue-cal__time-label--half': minutesSum % 60 !== 0,
              }"
            >
              {{ minutesSum % 30 === 0 ? format24 : '' }}
            </label>
          </template>

          <template #cell-content="{ cell }">
            <div
              v-if="view === 'month'"
              class="scheduling-vue-cal__month-cell-overlay"
              :class="{
                'scheduling-vue-cal__month-cell-overlay--holiday':
                  blockingHolidayForDay(cell.start),
                'scheduling-vue-cal__month-cell-overlay--today':
                  formatDateKey(cell.start) === todayDateKey,
              }"
            >
              <span
                v-if="blockingHolidayForDay(cell.start)"
                class="scheduling-vue-cal__month-badge scheduling-vue-cal__month-badge--holiday"
              >
                {{ blockingHolidayForDay(cell.start).title }}
              </span>
              <span
                v-if="formatMonthSlotMeta(cell.start)"
                class="scheduling-vue-cal__month-badge scheduling-vue-cal__month-badge--slots"
              >
                {{ formatMonthSlotMeta(cell.start) }}
              </span>
            </div>
          </template>

          <template #event="{ event }">
            <template v-if="event.background">
              <div
                class="scheduling-vue-cal__background-fill"
                :class="{
                  'scheduling-vue-cal__background-fill--unavailable':
                    isUnavailableBackgroundKind(event.backgroundKind),
                }"
              >
                <span
                  v-if="event.backgroundLabel"
                  class="scheduling-vue-cal__background-label"
                >
                  {{ event.backgroundLabel }}
                </span>
              </div>
            </template>

            <template v-else-if="view !== 'month'">
              <div
                class="scheduling-vue-cal__event-card"
                :class="{
                  'scheduling-vue-cal__event-card--muted':
                    isMutedAppointmentCard(event),
                  'scheduling-vue-cal__event-card--cancelled':
                    isCancelledAppointmentCard(event),
                }"
                :style="{
                  '--appointment-accent': event.resourceColor || '#2563eb',
                }"
                :title="eventTitle(event)"
              >
                <div class="scheduling-vue-cal__event-header">
                  <span class="scheduling-vue-cal__event-status-icon">
                    <span
                      class="size-[0.625rem] shrink-0"
                      :class="[resolveEventStatusIcon(event)]"
                      aria-hidden="true"
                    />
                    <span class="sr-only">
                      {{ resolveEventStatusLabel(event) }}
                    </span>
                  </span>

                  <div class="scheduling-vue-cal__event-summary">
                    <div
                      class="scheduling-vue-cal__event-meta"
                      :class="{
                        'scheduling-vue-cal__event-meta--surface':
                          isMutedAppointmentCard(event) ||
                          isCancelledAppointmentCard(event),
                      }"
                    >
                      <span class="scheduling-vue-cal__event-time">{{
                        formatEventTimeRange(event)
                      }}</span>
                    </div>

                    <div class="scheduling-vue-cal__event-title">
                      {{ event.clientName }}
                    </div>
                  </div>
                </div>

                <div
                  v-if="event.serviceNameSnapshot"
                  class="scheduling-vue-cal__event-subtitle"
                  :class="{
                    'scheduling-vue-cal__event-subtitle--surface':
                      isMutedAppointmentCard(event) ||
                      isCancelledAppointmentCard(event),
                  }"
                >
                  {{ event.serviceNameSnapshot }}
                </div>
              </div>
            </template>

            <template v-else-if="!event.background">
              <div
                class="truncate rounded-md px-1.5 py-0.5 text-[11px] font-medium"
                :style="{
                  backgroundColor: `${event.resourceColor || '#2563eb'}22`,
                  color: event.resourceColor || '#2563eb',
                }"
              >
                {{ formatTimeLabel(minuteOfDayFromDate(event.start)) }}
                {{ event.clientName }}
                <span v-if="event.resourceName" class="ml-1">
                  {{ event.resourceName }}
                </span>
              </div>
            </template>
          </template>
        </VueCal>
      </div>
    </div>
  </div>
</template>

<style scoped>
.scheduling-vue-cal {
  --appointment-accent: #2563eb;
  --scheduling-shell-bg: rgb(var(--solid-2));
  --scheduling-panel-bg: rgb(var(--surface-2));
  --scheduling-panel-muted-bg: rgb(var(--surface-1));
  display: flex;
  min-height: 0;
  height: 100%;
  flex-direction: column;
  background: var(--scheduling-shell-bg);
  box-shadow: none;
}

.scheduling-vue-cal__viewport {
  display: flex;
  flex: 1 1 auto;
  min-height: 0;
  min-width: 0;
}

.scheduling-vue-cal__frame {
  width: 100%;
  min-width: 0;
  height: 100%;
  margin: 0 auto;
}

.scheduling-vue-cal__calendar {
  --vuecal-height: 100%;
  --vuecal-schedules-bar-size: 0px;
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
}

.scheduling-vue-cal--day .scheduling-vue-cal__calendar {
  --vuecal-schedules-bar-size: 1.875rem;
}

.scheduling-vue-cal--week .scheduling-vue-cal__calendar {
  --vuecal-weekday-bar-size: var(--scheduling-weekday-bar-size, 2.05rem);
}

.scheduling-vue-cal :deep(.vuecal) {
  --scheduling-sticky-bg: rgb(var(--slate-2));
  --scheduling-slot-grid-bg: rgb(var(--surface-1));
  --scheduling-slot-divider: rgb(var(--slate-8) / 0.32);
  --scheduling-slot-half-hour-divider: rgb(var(--slate-9) / 0.16);
  --scheduling-slot-hour-divider: rgb(var(--slate-9) / 0.28);
  --scheduling-slot-dash-size: 8px;
  --scheduling-slot-dash-pattern: radial-gradient(
    ellipse 2px 0.4px at 2px 0.5px,
    var(--scheduling-slot-divider) 98%,
    transparent 100%
  );
  --scheduling-slot-grid: linear-gradient(
    0deg,
    var(--scheduling-slot-divider) 0,
    var(--scheduling-slot-divider) 1px,
    transparent 1px,
    transparent var(--vuecal-time-cell-size)
  );
  --vuecal-border-color: rgb(var(--slate-7) / 0.88);
  --vuecal-primary-color: rgb(var(--brand-color));
  --vuecal-secondary-color: var(--scheduling-sticky-bg);
  --vuecal-base-color: rgb(var(--slate-12));
  --vuecal-today-bg: rgb(var(--brand-color) / 0.08);
  --vuecal-active-color: rgb(var(--brand-color));
  border-radius: inherit;
  overflow: hidden;
  border: none;
  background: transparent;
}

.scheduling-vue-cal :deep(.vuecal__scrollable-wrap) {
  background: var(--scheduling-panel-muted-bg);
}

.scheduling-vue-cal :deep(.vuecal__headings) {
  isolation: isolate;
  background: var(--scheduling-panel-bg) !important;
  box-shadow: inset 0 -1px 0 0 var(--vuecal-border-color);
}

.scheduling-vue-cal :deep(.vuecal__schedule--heading) {
  height: 100%;
  align-items: stretch;
  overflow: visible;
  background: transparent !important;
  box-shadow:
    inset 0 -1px 0 0 var(--vuecal-border-color),
    inset -1px 0 0 0 var(--vuecal-border-color);
}

.scheduling-vue-cal :deep(.vuecal__weekdays-headings),
.scheduling-vue-cal :deep(.vuecal__schedules-headings),
.scheduling-vue-cal :deep(.vuecal__time-column) {
  isolation: isolate;
  background: var(--scheduling-panel-bg) !important;
}

.scheduling-vue-cal--week :deep(.vuecal__weekdays-headings) {
  flex: 0 0 var(--vuecal-weekday-bar-size);
  height: var(--vuecal-weekday-bar-size);
  max-height: var(--vuecal-weekday-bar-size);
  min-height: var(--vuecal-weekday-bar-size);
}

.scheduling-vue-cal :deep(.vuecal__weekday) {
  background: transparent !important;
  box-shadow:
    inset 0 -1px 0 0 var(--vuecal-border-color),
    inset -1px 0 0 0 var(--vuecal-border-color);
  align-items: stretch;
  justify-content: flex-start;
  gap: 0;
  color: rgb(var(--slate-12));
  font-size: 0.78em;
  letter-spacing: 0.02em;
}

.scheduling-vue-cal--week :deep(.vuecal__weekday) {
  min-height: 100%;
  padding-top: 0.3125rem;
  padding-bottom: 0.25rem;
}

.scheduling-vue-cal--week-single-line :deep(.vuecal__weekday) {
  align-items: center;
  justify-content: center;
  padding-top: 0;
  padding-bottom: 0;
}

.scheduling-vue-cal :deep(.vuecal__weekday--today) {
  background: color-mix(
    in srgb,
    rgb(var(--brand-color)) 6%,
    var(--scheduling-panel-bg)
  ) !important;
  color: rgb(var(--slate-12));
  box-shadow:
    inset 0 -1px 0 0 var(--vuecal-border-color),
    inset -1px 0 0 0 var(--vuecal-border-color);
}

.scheduling-vue-cal :deep(.vuecal__weekday-day) {
  font-size: 0.78em;
  font-weight: 500;
}

.scheduling-vue-cal :deep(.vuecal__weekday-date) {
  display: inline;
  width: auto;
  padding: 0;
  border-radius: 0;
  background: none !important;
  font-size: 0.78em;
  font-weight: 500;
  letter-spacing: 0;
  text-indent: 0;
}

.scheduling-vue-cal__weekday-heading {
  display: flex;
  width: 100%;
  min-width: 0;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.125rem;
  padding: 0 0.5rem;
}

.scheduling-vue-cal--week-single-line .scheduling-vue-cal__weekday-heading {
  min-height: 100%;
  justify-content: center;
  padding-top: 0;
  padding-bottom: 0;
}

.scheduling-vue-cal__weekday-primary {
  display: flex;
  min-width: 0;
  align-items: center;
  gap: 0.25rem;
}

.scheduling-vue-cal__weekday-text {
  font-size: 0.78em;
  font-weight: 500;
  line-height: 1.1;
  color: inherit;
}

.scheduling-vue-cal__weekday-secondary {
  max-width: 100%;
  color: rgb(var(--slate-9));
  font-size: 0.625rem;
  font-weight: 500;
  line-height: 1.1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.scheduling-vue-cal__weekday-holiday-dot {
  width: 0.375rem;
  height: 0.375rem;
  flex-shrink: 0;
  border-radius: 9999px;
  background: rgb(var(--ruby-9));
}

.scheduling-vue-cal :deep(.vuecal__schedule--cell) {
  background: transparent;
}

.scheduling-vue-cal :deep(.vuecal__body) {
  position: relative;
  background: rgb(var(--surface-1));
}

.scheduling-vue-cal--day :deep(.vuecal__body),
.scheduling-vue-cal--week :deep(.vuecal__body) {
  background: rgb(var(--surface-1));
}

.scheduling-vue-cal :deep(.vuecal__cell) {
  background-color: transparent;
  background-image: linear-gradient(
      var(--vuecal-border-color),
      var(--vuecal-border-color)
    ),
    repeating-linear-gradient(
      0deg,
      transparent 0 calc(var(--scheduling-hour-grid-size) - 1px),
      var(--scheduling-slot-hour-divider)
        calc(var(--scheduling-hour-grid-size) - 1px)
        var(--scheduling-hour-grid-size)
    ),
    repeating-linear-gradient(
      0deg,
      transparent 0 calc(var(--scheduling-half-hour-grid-size) - 1px),
      var(--scheduling-slot-half-hour-divider)
        calc(var(--scheduling-half-hour-grid-size) - 1px)
        var(--scheduling-half-hour-grid-size)
    ),
    repeating-linear-gradient(
      0deg,
      transparent 0 calc(var(--scheduling-half-hour-grid-size) - 1px),
      var(--scheduling-slot-grid-bg)
        calc(var(--scheduling-half-hour-grid-size) - 1px)
        var(--scheduling-half-hour-grid-size)
    ),
    var(--scheduling-slot-dash-pattern);
  background-repeat: no-repeat, no-repeat, no-repeat, no-repeat, repeat;
  background-position:
    right top,
    0 calc(var(--scheduling-hour-grid-offset) + 1px),
    0 calc(var(--scheduling-half-hour-grid-offset) + 1px),
    0 calc(var(--scheduling-half-hour-grid-offset) + 1px),
    0 1px;
  background-size:
    1px 100%,
    100% 100%,
    100% 100%,
    100% 100%,
    var(--scheduling-slot-dash-size) var(--vuecal-time-cell-size);
  box-shadow: none;
}

.scheduling-vue-cal :deep(.vuecal__scrollable--month-view .vuecal__cell) {
  background-image: linear-gradient(
      var(--vuecal-border-color),
      var(--vuecal-border-color)
    ),
    linear-gradient(
      90deg,
      var(--vuecal-border-color),
      var(--vuecal-border-color)
    );
  background-repeat: no-repeat;
  background-position:
    right top,
    left bottom;
  background-size:
    1px 100%,
    100% 1px;
}

.scheduling-vue-cal
  :deep(.vuecal__scrollable--month-view .vuecal__cell--today) {
  background: color-mix(
    in srgb,
    rgb(var(--brand-color)) 14%,
    rgb(var(--surface-1))
  ) !important;
  box-shadow:
    inset 0 0 0 1px rgb(var(--brand-color) / 0.32),
    inset -1px 0 0 0 var(--vuecal-border-color),
    inset 0 -1px 0 0 var(--vuecal-border-color);
}

.scheduling-vue-cal
  :deep(
    .vuecal__scrollable--month-view .vuecal__cell--today .vuecal__cell-date
  ) {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 1.4rem;
  height: 1.4rem;
  padding: 0 0.4rem;
  border-radius: 9999px;
  background: rgb(var(--brand-color));
  color: white !important;
  box-shadow: 0 1px 2px rgb(var(--slate-12) / 0.12);
}

.scheduling-vue-cal--day :deep(.vuecal__cell::after),
.scheduling-vue-cal--week :deep(.vuecal__cell::after) {
  display: none;
}

.scheduling-vue-cal__month-cell-overlay {
  display: flex;
  height: 100%;
  flex-direction: column;
  align-items: flex-end;
  gap: 0.25rem;
  padding: 1.55rem 0.35rem 0.35rem;
  border-radius: 0.75rem;
}

.scheduling-vue-cal__month-cell-overlay--today {
  background: linear-gradient(
    180deg,
    rgb(var(--brand-color) / 0.08),
    transparent 52%
  );
}

.scheduling-vue-cal__month-cell-overlay--holiday {
  background: linear-gradient(
    180deg,
    rgb(var(--ruby-5) / 0.24),
    transparent 60%
  );
}

.scheduling-vue-cal__month-badge {
  display: inline-flex;
  align-items: center;
  max-width: 100%;
  border-radius: 9999px;
  padding: 0.125rem 0.45rem;
  font-size: 0.625rem;
  font-weight: 600;
  line-height: 1.2;
  box-shadow: 0 1px 2px rgb(var(--slate-12) / 0.06);
}

.scheduling-vue-cal__month-badge--holiday {
  background: rgb(var(--ruby-5));
  color: rgb(var(--ruby-11));
}

.scheduling-vue-cal__month-badge--slots {
  background: rgb(var(--teal-4));
  color: rgb(var(--teal-11));
}

.scheduling-vue-cal :deep(.vuecal__cell--sat),
.scheduling-vue-cal :deep(.vuecal__cell--sun) {
  background-color: rgb(var(--alpha-1));
}

.scheduling-vue-cal :deep(.vuecal__time-cell),
.scheduling-vue-cal :deep(.vuecal__all-day-label) {
  background: transparent !important;
}

.scheduling-vue-cal :deep(.vuecal__time-cell) {
  align-items: flex-start;
  justify-content: flex-start;
}

.scheduling-vue-cal :deep(.vuecal__time-cell::before) {
  top: 1px;
  left: 0;
  right: 0;
  width: auto;
  height: 1px;
  border-top: 1px solid transparent;
  background: none;
}

.scheduling-vue-cal :deep(.vuecal__time-cell--half-hour::before) {
  border-top-color: var(--scheduling-slot-half-hour-divider);
}

.scheduling-vue-cal :deep(.vuecal__time-cell--hour::before) {
  border-top-color: var(--scheduling-slot-hour-divider);
}

.scheduling-vue-cal :deep(.vuecal__time-cell label) {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.25rem;
  width: 100%;
  padding-left: 0.4rem;
  padding-right: 0.4rem;
  padding-top: 0.18rem;
  line-height: 1.1;
  text-align: center;
  letter-spacing: 0;
}

.scheduling-vue-cal :deep(.vuecal__time-cell:first-child label) {
  padding-top: 0.18rem;
}

.scheduling-vue-cal__time-label--hour {
  color: var(--vuecal-base-color);
  font-size: 0.7em;
  font-weight: 500;
}

.scheduling-vue-cal__time-label--muted {
  color: transparent;
}

.scheduling-vue-cal__time-label--half {
  color: rgb(var(--slate-9));
  font-size: 0.55rem;
  font-weight: 500;
}

.scheduling-vue-cal--day :deep(.vuecal__cell-content),
.scheduling-vue-cal--week :deep(.vuecal__cell-content) {
  position: absolute;
  inset: 0;
  pointer-events: none;
}

.scheduling-vue-cal
  :deep(
    .vuecal__scrollable--no-schedules.vuecal__scrollable--day-view
      .vuecal__cell-events
  ),
.scheduling-vue-cal
  :deep(
    .vuecal__scrollable--no-schedules.vuecal__scrollable--days-view
      .vuecal__cell-events
  ),
.scheduling-vue-cal
  :deep(
    .vuecal__scrollable--no-schedules.vuecal__scrollable--week-view
      .vuecal__cell-events
  ) {
  inset: 0;
}

.scheduling-vue-cal--week
  :deep(
    .vuecal__scrollable--no-schedules.vuecal__scrollable--week-view
      .vuecal__event:not(.vuecal__event--background)
  ) {
  left: 4px;
  right: 4px;
}

.scheduling-vue-cal :deep(.vuecal__cell--today) {
  background-color: transparent;
}

.scheduling-vue-cal :deep(.vuecal__now-line) {
  border-color: rgb(var(--brand-color) / 0.58);
  box-shadow: 0 0 0 1px rgb(var(--brand-color) / 0.06);
}

.scheduling-vue-cal :deep(.vuecal__now-line span) {
  display: inline-flex;
  align-items: center;
  border-radius: 9999px;
  background: rgb(var(--surface-2));
  color: rgb(var(--brand-color));
  box-shadow:
    0 1px 2px rgb(var(--slate-12) / 0.06),
    inset 0 0 0 1px rgb(var(--brand-color) / 0.12);
  padding: 0.125rem 0.375rem;
  font-size: 0.625rem;
  font-weight: 600;
}

.scheduling-vue-cal :deep(.vuecal__cell-date) {
  font-size: 0.75rem;
  font-weight: 600;
  color: rgb(var(--slate-11));
}

.scheduling-vue-cal :deep(.vuecal__event) {
  border: 0;
  box-shadow: none;
  padding: 0;
}

.scheduling-vue-cal :deep(.vuecal__event-details) {
  display: flex;
  flex-grow: 1;
  min-height: 0;
  overflow: hidden;
  padding: 0;
  pointer-events: none;
  font-size: inherit;
}

.scheduling-vue-cal :deep(.vuecal__event:not(.vuecal__event--background)) {
  min-width: 0;
  pointer-events: none;
  overflow: visible;
  background: transparent !important;
  transition:
    filter 0.16s ease,
    box-shadow 0.16s ease,
    left 0.16s ease,
    width 0.16s ease;
}

.scheduling-vue-cal :deep(.vuecal__event-placeholder) {
  left: 0.25rem;
  right: 0.25rem;
  border: 1px solid rgb(var(--brand-color) / 0.92);
  border-radius: 0.25rem;
  background: color-mix(
    in srgb,
    rgb(var(--brand-color)) 84%,
    rgb(var(--surface-1))
  );
  color: white;
  box-shadow: 0 1px 2px rgb(var(--slate-12) / 0.08);
  padding: 0.18rem 0.3rem 0;
  font-size: 0.625rem;
  font-weight: 600;
  letter-spacing: 0.01em;
  opacity: 0.96;
}

.scheduling-vue-cal--week :deep(.vuecal__event-placeholder) {
  left: 0.25rem;
  right: 0.25rem;
}

.scheduling-vue-cal :deep(.vuecal__event-resizer) {
  pointer-events: auto;
  background: transparent !important;
  opacity: 0 !important;
}

.scheduling-vue-cal :deep(.vuecal__event-resizer:hover) {
  opacity: 0 !important;
}

.scheduling-vue-cal
  :deep(.vuecal__event:not(.vuecal__event--background):hover) {
  transform: none;
  filter: none;
}

.scheduling-vue-cal :deep(.vuecal__event--background) {
  opacity: 1;
  pointer-events: none;
  overflow: visible;
  background: transparent !important;
}

.scheduling-vue-cal :deep(.vuecal__event--background .vuecal__event-details) {
  height: 100%;
  padding: 0;
  overflow: visible;
}

.scheduling-vue-cal :deep(.scheduling-vue-cal__background-event) {
  margin: 0;
  border-radius: 0;
  background: transparent !important;
  box-shadow: none;
}

.scheduling-vue-cal__background-fill {
  display: flex;
  height: 100%;
  width: 100%;
  align-items: flex-start;
  justify-content: flex-start;
  padding: 0;
  border-radius: 0;
  box-shadow: none;
  overflow: visible;
}

.scheduling-vue-cal__background-fill--unavailable {
  background: rgb(var(--slate-6) / 0.24);
}

.scheduling-vue-cal__background-label {
  display: block;
  width: 100%;
  max-width: 100%;
  padding: 0.1875rem 0.25rem;
  border: 0;
  border-radius: 0;
  background: none;
  color: rgb(var(--slate-11));
  box-shadow: none;
  font-size: 0.625rem;
  font-weight: 500;
  line-height: 1.2;
  white-space: normal;
  overflow-wrap: anywhere;
  word-break: break-word;
  position: relative;
  z-index: 1;
}

.scheduling-vue-cal
  :deep(.scheduling-vue-cal__background-event.vuecal__event--background) {
  background: transparent !important;
  box-shadow: none;
}

.scheduling-vue-cal__schedule-heading {
  display: flex;
  height: 100%;
  min-width: 0;
  align-items: center;
}

.scheduling-vue-cal--day .scheduling-vue-cal__schedule-heading {
  padding-top: 0.375rem;
  padding-bottom: 0.375rem;
}

.scheduling-vue-cal--week .scheduling-vue-cal__schedule-heading {
  padding-top: 0.1875rem;
}

.scheduling-vue-cal__schedule-chip {
  display: inline-flex;
  max-width: 100%;
  align-items: center;
  gap: 0.1875rem;
  margin: auto 0;
  padding: 0.25rem 0.4375rem;
  border: 1px solid var(--schedule-accent);
  border-radius: 0.75rem;
  background: color-mix(
    in srgb,
    var(--schedule-accent) 12%,
    rgb(var(--surface-1))
  );
  box-shadow:
    0 1px 2px rgb(var(--slate-12) / 0.04),
    inset 0 1px 0 rgb(var(--surface-2) / 0.28);
}

.scheduling-vue-cal--day .scheduling-vue-cal__schedule-chip {
  gap: 0.375rem;
  padding: 0;
  border: 0;
  border-radius: 0;
  background: none;
  box-shadow: none;
}

.scheduling-vue-cal--week .scheduling-vue-cal__schedule-chip {
  margin-top: 0;
  margin-bottom: auto;
}

.scheduling-vue-cal__schedule-chip--week {
  gap: 0.125rem;
  padding: 0.125rem 0.3125rem;
  border-color: var(--schedule-accent);
  background: color-mix(
    in srgb,
    var(--schedule-accent) 16%,
    rgb(var(--surface-1))
  );
}

.scheduling-vue-cal__schedule-dot {
  width: 0.5rem;
  height: 0.5rem;
  flex-shrink: 0;
  border-radius: 9999px;
}

.scheduling-vue-cal__schedule-label {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 0.25rem;
  min-width: 0;
  color: color-mix(in srgb, var(--vuecal-base-color) 80%, transparent);
  font-size: 0.75rem;
  font-weight: 500;
  letter-spacing: 0;
  line-height: 1.1;
  white-space: nowrap;
}

.scheduling-vue-cal--day .scheduling-vue-cal__schedule-label {
  justify-content: flex-start;
}

.scheduling-vue-cal__schedule-label--week {
  gap: 0.1875rem;
  font-size: 0.6875rem;
  font-weight: 500;
  letter-spacing: 0.06em;
  line-height: 1;
  text-transform: uppercase;
}

.scheduling-vue-cal__event-card {
  --event-slot-inset-top: 0.25rem;
  --event-slot-inset-right: 0.25rem;
  --event-slot-inset-bottom: 0.25rem;
  --event-slot-inset-left: 0.25rem;
  display: flex;
  flex: 0 0 auto;
  flex-direction: column;
  justify-content: flex-start;
  gap: 0.05rem;
  height: calc(
    100% - var(--event-slot-inset-top) - var(--event-slot-inset-bottom)
  );
  width: calc(
    100% - var(--event-slot-inset-left) - var(--event-slot-inset-right)
  );
  min-width: 0;
  margin: var(--event-slot-inset-top) var(--event-slot-inset-right)
    var(--event-slot-inset-bottom) var(--event-slot-inset-left);
  overflow: hidden;
  border-radius: 0.25rem;
  border: 1px solid
    color-mix(in srgb, var(--appointment-accent) 86%, rgb(var(--slate-8)));
  background: color-mix(
    in srgb,
    var(--appointment-accent) 84%,
    rgb(var(--surface-1))
  );
  color: white;
  box-shadow: 0 1px 2px rgb(var(--slate-12) / 0.08);
  padding: 0.1rem 0.1rem;
  pointer-events: auto;
  transition:
    transform 0.16s ease,
    box-shadow 0.16s ease;
}

.scheduling-vue-cal__event-card--muted {
  border-color: rgb(var(--slate-7) / 0.5);
  background: rgb(var(--slate-3));
  color: rgb(var(--slate-12));
}

.scheduling-vue-cal__event-card--cancelled {
  border-color: rgb(var(--ruby-7) / 0.3);
  background: rgb(var(--ruby-4) / 0.88);
  color: rgb(var(--ruby-11));
}

.scheduling-vue-cal__event-header {
  display: flex;
  align-items: center;
  gap: 0.125rem;
  min-width: 0;
}

.scheduling-vue-cal__event-status-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 0.9375rem;
  height: 0.9375rem;
  flex: 0 0 auto;
  color: currentColor;
}

.scheduling-vue-cal__event-summary {
  display: flex;
  align-items: center;
  gap: 0.1875rem;
  min-width: 0;
  flex: 1 1 auto;
  overflow: hidden;
}

.scheduling-vue-cal__event-meta {
  display: inline-flex;
  align-items: center;
  gap: 0.1875rem;
  flex: 0 0 auto;
  color: rgb(255 255 255 / 0.88);
  font-size: 0.5625rem;
  font-weight: 600;
  line-height: 1;
}

.scheduling-vue-cal__event-meta--surface {
  color: rgb(var(--slate-11));
}

.scheduling-vue-cal__event-title {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 0.6875rem;
  font-weight: 600;
  line-height: 1.05;
}

.scheduling-vue-cal__event-time {
  white-space: nowrap;
}

.scheduling-vue-cal__event-subtitle {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 0.625rem;
  font-weight: 500;
  line-height: 1.05;
  color: rgb(255 255 255 / 0.84);
}

.scheduling-vue-cal__event-subtitle--surface {
  color: rgb(var(--slate-10));
}
</style>
