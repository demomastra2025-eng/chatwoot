<script setup>
import { computed, toRef } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { VueCal } from 'vue-cal';

import {
  DEFAULT_VISIBLE_END_MINUTE,
  DEFAULT_VISIBLE_START_MINUTE,
  HOUR_ROW_HEIGHT,
  MINUTE_STEP,
} from 'dashboard/routes/dashboard/scheduling/constants';
import {
  buildBreakIntervals,
  buildCalendarColumns,
  buildDayListForView,
  buildTimeOffIntervals,
  deriveVisibleMinuteWindow,
  formatDateKey,
  formatTimeLabel,
  minuteOfDayFromDate,
  snapMinute,
  toDate,
} from 'dashboard/routes/dashboard/scheduling/helpers';
import { useSchedulingCalendarIndexes } from 'dashboard/routes/dashboard/scheduling/composables/useSchedulingCalendarIndexes';

const TIMELINE_ROW_HEIGHT_MULTIPLIER = 1.125;

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
  holidays: {
    type: Array,
    default: () => [],
  },
  resources: {
    type: Array,
    default: () => [],
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

const { t, locale } = useI18n();

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
  isRangeAvailable,
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

const resourceById = computed(() => {
  return props.resources.reduce((result, resource) => {
    result[resource.id] = resource;
    return result;
  }, {});
});

const timelineStepMin = computed(() =>
  Math.max(MINUTE_STEP, slotStepMin.value || MINUTE_STEP)
);

const visibleWindow = computed(() => {
  const baseWindow = deriveVisibleMinuteWindow({
    appointments: props.appointments,
    columns: columns.value,
    workRules: props.workRules,
    workdayOverrides: props.workdayOverrides,
  });

  if (!isTimelineView.value || !props.slots.length) {
    return baseWindow;
  }

  const slotMinutes = props.slots.flatMap(slot => [
    minuteOfDayFromDate(toDate(slot.startsAt)),
    minuteOfDayFromDate(toDate(slot.endsAt)),
  ]);

  if (!slotMinutes.length) {
    return baseWindow;
  }

  const stepMin = timelineStepMin.value;
  const paddingMin = Math.max(30, stepMin);
  const startMinute = Math.max(
    0,
    Math.floor(
      (Math.min(...slotMinutes, baseWindow.startMinute) - paddingMin) / stepMin
    ) * stepMin
  );
  const endMinute = Math.min(
    24 * 60,
    Math.ceil(
      (Math.max(...slotMinutes, baseWindow.endMinute) + paddingMin) / stepMin
    ) * stepMin
  );

  return {
    startMinute: Math.min(startMinute, DEFAULT_VISIBLE_START_MINUTE),
    endMinute: Math.max(endMinute, DEFAULT_VISIBLE_END_MINUTE),
  };
});

const timeCellHeight = computed(() => {
  return (
    HOUR_ROW_HEIGHT *
    TIMELINE_ROW_HEIGHT_MULTIPLIER *
    (timelineStepMin.value / 60)
  );
});

const schedules = computed(() => {
  return props.resources.map(resource => ({
    id: resource.id,
    label: resource.name,
  }));
});

const timelineBackgroundEvents = computed(() => {
  if (!isTimelineView.value) {
    return [];
  }

  return columns.value.flatMap(column => {
    const events = [];
    const holiday = blockingHolidayForDay(column.date);

    if (holiday) {
      const start = new Date(column.date);
      start.setHours(0, 0, 0, 0);
      const end = new Date(start);
      end.setDate(end.getDate() + 1);

      events.push({
        id: `holiday-${column.resourceId}-${column.dateKey}`,
        start,
        end,
        schedule: column.resourceId,
        background: true,
        class:
          'scheduling-vue-cal__background-event scheduling-vue-cal__background-event--holiday',
      });
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

    return {
      id: String(appointment.id),
      start: toDate(appointment.startsAt),
      end: toDate(appointment.endsAt),
      title: appointment.clientName,
      schedule: appointment.resourceId,
      appointment,
      status: appointment.status,
      paymentStatus: appointment.paymentStatus,
      clientName: appointment.clientName,
      serviceNameSnapshot: appointment.serviceNameSnapshot,
      resourceColor: resource?.color || '#2563eb',
      resourceName: resource?.name || '—',
      durationMin: appointment.durationMin,
      class: `scheduling-vue-cal__appointment scheduling-vue-cal__appointment--${appointment.status || 'scheduled'}`,
    };
  });
});

const calendarEvents = computed(() => {
  return [...timelineBackgroundEvents.value, ...appointmentEvents.value];
});

const editableEvents = computed(() => {
  if (!isTimelineView.value) {
    return {
      create: false,
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

const paymentStatusLabel = status => {
  const labels = {
    awaiting_payment: t('SCHEDULING.PAYMENT_STATUS.awaiting_payment'),
    cancelled: t('SCHEDULING.PAYMENT_STATUS.cancelled'),
    paid: t('SCHEDULING.PAYMENT_STATUS.paid'),
    prepaid: t('SCHEDULING.PAYMENT_STATUS.prepaid'),
  };

  return labels[status] || labels.awaiting_payment;
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

const resolveClickedResourceId = ({ cell, e }) => {
  const rawSchedule =
    cell?.schedule ||
    e?.target?.closest?.('[data-schedule]')?.dataset?.schedule ||
    props.resources[0]?.id;
  const resourceId = Number(rawSchedule);

  return Number.isFinite(resourceId) && resourceId > 0 ? resourceId : null;
};

const buildTimelineClickPayload = ({ cell, cursor, e }) => {
  const resourceId = resolveClickedResourceId({ cell, e });
  if (!resourceId || !cursor?.date) {
    return null;
  }

  const startsAt = new Date(cell.start);
  startsAt.setHours(0, 0, 0, 0);
  startsAt.setMinutes(
    snapMinute(minuteOfDayFromDate(cursor.date), timelineStepMin.value),
    0,
    0
  );

  const durationMin = Math.max(
    timelineStepMin.value,
    Number(resourceById.value[resourceId]?.slotDurationMin) ||
      timelineStepMin.value
  );
  const endsAt = new Date(startsAt);
  endsAt.setMinutes(endsAt.getMinutes() + durationMin);

  if (
    !isRangeAvailable({
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
};

const handleCellClick = payload => {
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
    unavailableSlotMessage();
    return;
  }

  emit('createAppointment', timelinePayload);
};

const handleEventCreate = ({ event, resolve }) => {
  const resourceId = Number(event.schedule || props.resources[0]?.id);
  const startsAt = new Date(event.start);
  const endsAt = new Date(event.end);

  if (
    !resourceId ||
    !isRangeAvailable({
      resourceId,
      startsAt,
      endsAt,
    })
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
  const appointment = event.appointment;
  const resourceId = Number(event.schedule || appointment?.resourceId);
  const startsAt = new Date(event.start);
  const endsAt = new Date(event.end);

  if (
    !appointment ||
    !resourceId ||
    !isRangeAvailable({
      resourceId,
      startsAt,
      endsAt,
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
  const appointment = event.appointment;
  const startsAt = new Date(event.start);
  const endsAt = new Date(event.end);

  if (
    !appointment ||
    !isRangeAvailable({
      resourceId: appointment.resourceId,
      startsAt,
      endsAt,
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

const handleEventClick = ({ event }) => {
  if (event.background) {
    return;
  }

  emit('selectAppointment', event.appointment);
};
</script>

<template>
  <div class="scheduling-vue-cal">
    <VueCal
      class="scheduling-vue-cal__calendar"
      :locale="localeCode"
      :events="calendarEvents"
      :schedules="schedules"
      :editable-events="editableEvents"
      events-on-month-view="short"
      :snap-to-interval="timelineStepMin"
      :time="view !== 'month'"
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
      @event-drop="handleEventDrop"
      @event-resize-end="handleEventResizeEnd"
    >
      <template #schedule-heading="{ schedule }">
        <div class="scheduling-vue-cal__schedule-heading">
          <span
            class="scheduling-vue-cal__schedule-dot"
            :style="{
              backgroundColor: resourceById[schedule.id]?.color || '#2563eb',
            }"
          />
          <div class="min-w-0">
            <div class="truncate text-sm font-semibold text-n-slate-12">
              {{ resourceById[schedule.id]?.name || schedule.label }}
            </div>
            <div
              v-if="resourceById[schedule.id]?.specialty"
              class="truncate text-[11px] text-n-slate-10"
            >
              {{ resourceById[schedule.id]?.specialty }}
            </div>
          </div>
        </div>
      </template>

      <template #cell-content="{ cell }">
        <div
          v-if="view === 'month'"
          class="pointer-events-none flex h-full flex-col items-end gap-1 px-1 pb-1 pt-6"
        >
          <span
            v-if="blockingHolidayForDay(cell.start)"
            class="inline-flex items-center rounded-full bg-n-ruby-4 px-1.5 py-0.5 text-[10px] font-medium text-n-ruby-11"
          >
            {{ blockingHolidayForDay(cell.start).title }}
          </span>
          <span
            v-if="formatMonthSlotMeta(cell.start)"
            class="inline-flex items-center rounded-full bg-n-teal-4 px-1.5 py-0.5 text-[10px] font-medium text-n-teal-11"
          >
            {{ formatMonthSlotMeta(cell.start) }}
          </span>
        </div>
      </template>

      <template #event="{ event }">
        <template v-if="!event.background && view !== 'month'">
          <div
            class="scheduling-vue-cal__event-card"
            :style="{
              '--appointment-accent': event.resourceColor || '#2563eb',
            }"
          >
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0">
                <div class="truncate font-semibold text-n-slate-12">
                  {{ event.clientName }}
                </div>
                <div class="truncate text-[11px] text-n-slate-11">
                  {{
                    event.serviceNameSnapshot ||
                    t('SCHEDULING.CALENDAR.NO_SERVICE')
                  }}
                </div>
              </div>
              <div class="shrink-0 text-[11px] font-medium text-n-slate-11">
                {{ formatTimeLabel(minuteOfDayFromDate(event.start)) }}
              </div>
            </div>

            <div class="mt-1 flex items-center justify-between gap-2">
              <span
                class="truncate text-[11px]"
                :class="
                  event.paymentStatus === 'paid'
                    ? 'text-n-teal-11'
                    : event.paymentStatus === 'prepaid'
                      ? 'text-n-blue-11'
                      : event.paymentStatus === 'cancelled'
                        ? 'text-n-ruby-11'
                        : 'text-n-amber-11'
                "
              >
                {{
                  paymentStatusLabel(event.paymentStatus || 'awaiting_payment')
                }}
              </span>
              <span
                class="rounded-full px-2 py-0.5 text-[10px] font-medium"
                :class="
                  event.status === 'completed'
                    ? 'bg-n-teal-4 text-n-teal-11'
                    : event.status === 'confirmed'
                      ? 'bg-n-blue-4 text-n-blue-11'
                      : event.status === 'cancelled'
                        ? 'bg-n-ruby-4 text-n-ruby-11'
                        : event.status === 'no_show'
                          ? 'bg-n-amber-4 text-n-amber-11'
                          : 'bg-n-slate-4 text-n-slate-11'
                "
              >
                {{ appointmentStatusLabel(event.status) }}
              </span>
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
          </div>
        </template>
      </template>
    </VueCal>
  </div>
</template>

<style scoped>
.scheduling-vue-cal {
  --appointment-accent: #2563eb;
  display: flex;
  min-height: 0;
  height: 100%;
  flex-direction: column;
}

.scheduling-vue-cal__calendar {
  --vuecal-height: 100%;
  --vuecal-schedules-bar-size: 3.75rem;
  flex: 1 1 auto;
  min-height: 0;
}

.scheduling-vue-cal :deep(.vuecal) {
  --scheduling-sticky-bg: var(--n-surface-1);
  --vuecal-border-color: color-mix(in srgb, var(--n-slate-7) 88%, transparent);
  --vuecal-primary-color: var(--n-brand);
  --vuecal-secondary-color: var(--scheduling-sticky-bg);
  --vuecal-base-color: var(--n-slate-12);
  --vuecal-today-bg: color-mix(in srgb, var(--n-brand) 8%, transparent);
  --vuecal-active-color: var(--n-brand);
  border-radius: 1rem;
  overflow: hidden;
  border: 1px solid color-mix(in srgb, var(--n-slate-6) 55%, transparent);
  background: var(--n-surface-1);
}

.scheduling-vue-cal :deep(.vuecal__scrollable-wrap) {
  background: var(--n-surface-1);
}

.scheduling-vue-cal :deep(.vuecal__headings) {
  isolation: isolate;
  background: var(--scheduling-sticky-bg);
  box-shadow: inset 0 -1px 0 0 var(--vuecal-border-color);
}

.scheduling-vue-cal :deep(.vuecal__schedule--heading) {
  height: 100%;
  align-items: stretch;
  background: var(--scheduling-sticky-bg);
  box-shadow:
    inset 0 -1px 0 0 var(--vuecal-border-color),
    inset -1px 0 0 0 var(--vuecal-border-color);
}

.scheduling-vue-cal :deep(.vuecal__weekdays-headings),
.scheduling-vue-cal :deep(.vuecal__schedules-headings),
.scheduling-vue-cal :deep(.vuecal__time-column) {
  isolation: isolate;
  background: var(--scheduling-sticky-bg);
}

.scheduling-vue-cal :deep(.vuecal__weekday) {
  background: var(--scheduling-sticky-bg);
  box-shadow:
    inset 0 -1px 0 0 var(--vuecal-border-color),
    inset -1px 0 0 0 var(--vuecal-border-color);
}

.scheduling-vue-cal :deep(.vuecal__schedule--cell) {
  background: transparent;
}

.scheduling-vue-cal :deep(.vuecal__body) {
  background: var(--n-solid-2);
}

.scheduling-vue-cal :deep(.vuecal__cell) {
  background: transparent;
  box-shadow: 0 0 0 0.5px var(--vuecal-border-color) inset;
}

.scheduling-vue-cal :deep(.vuecal__time-cell),
.scheduling-vue-cal :deep(.vuecal__all-day-label) {
  background: var(--scheduling-sticky-bg);
}

.scheduling-vue-cal :deep(.vuecal__cell--today) {
  background: transparent;
}

.scheduling-vue-cal :deep(.vuecal__cell-date) {
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--n-slate-11);
}

.scheduling-vue-cal :deep(.vuecal__event) {
  border: 0;
  box-shadow: none;
  padding: 0;
}

.scheduling-vue-cal :deep(.vuecal__event--background) {
  opacity: 1;
  pointer-events: none;
}

.scheduling-vue-cal :deep(.scheduling-vue-cal__background-event) {
  border-radius: 0.75rem;
  margin: 0.125rem;
}

.scheduling-vue-cal
  :deep(
    .scheduling-vue-cal__background-event--holiday.vuecal__event--background
  ) {
  background: color-mix(in srgb, var(--n-ruby-6) 26%, transparent);
}

.scheduling-vue-cal
  :deep(
    .scheduling-vue-cal__background-event--break.vuecal__event--background
  ) {
  background: color-mix(in srgb, var(--n-amber-6) 22%, transparent);
}

.scheduling-vue-cal
  :deep(
    .scheduling-vue-cal__background-event--time-off.vuecal__event--background
  ) {
  background: color-mix(in srgb, var(--n-ruby-7) 18%, transparent);
}

.scheduling-vue-cal__schedule-heading {
  display: flex;
  height: 100%;
  min-width: 0;
  align-items: center;
  gap: 0.625rem;
  padding: 0.625rem 0.75rem;
  background: var(--scheduling-sticky-bg);
}

.scheduling-vue-cal__schedule-dot {
  width: 0.625rem;
  height: 0.625rem;
  flex-shrink: 0;
  border-radius: 9999px;
}

.scheduling-vue-cal__event-card {
  height: 100%;
  border-radius: 0.875rem;
  border: 1px solid color-mix(in srgb, var(--appointment-accent) 28%, white);
  background: linear-gradient(
    135deg,
    color-mix(in srgb, var(--appointment-accent) 15%, white) 0%,
    color-mix(in srgb, var(--appointment-accent) 32%, white) 100%
  );
  padding: 0.5rem 0.625rem;
}
</style>
