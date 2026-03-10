<script setup>
import { computed, onBeforeUnmount, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import {
  DEFAULT_VISIBLE_END_MINUTE,
  DEFAULT_VISIBLE_START_MINUTE,
  MINUTE_HEIGHT,
  MIN_APPOINTMENT_MINUTES,
} from 'dashboard/routes/dashboard/scheduling/constants';
import {
  buildBreakIntervals,
  buildCalendarColumns,
  buildDayListForView,
  buildTimeOffIntervals,
  clampMinute,
  dayMatchesHoliday,
  deriveVisibleMinuteWindow,
  formatDateKey,
  formatTimeLabel,
  getAppointmentsForColumn,
  minuteOfDayFromDate,
  snapMinute,
  toDate,
} from 'dashboard/routes/dashboard/scheduling/helpers';

import SchedulingAppointmentCard from './SchedulingAppointmentCard.vue';

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

const { t } = useI18n();

const columnRefs = ref({});
const interaction = ref(null);
let handlePointerUp = () => {};

const isTimelineView = computed(() => ['day', 'week'].includes(props.view));
const isMonthView = computed(() => props.view === 'month');
const isListView = computed(() => props.view === 'list');

const columns = computed(() => {
  return buildCalendarColumns(props.view, props.anchorDate, props.resources);
});

const visibleWindow = computed(() => {
  if (!isTimelineView.value) {
    return {
      endMinute: DEFAULT_VISIBLE_END_MINUTE,
      startMinute: DEFAULT_VISIBLE_START_MINUTE,
    };
  }

  return deriveVisibleMinuteWindow({
    appointments: props.appointments,
    columns: columns.value,
    workRules: props.workRules,
    workdayOverrides: props.workdayOverrides,
  });
});

const visibleMinutes = computed(() => {
  return visibleWindow.value.endMinute - visibleWindow.value.startMinute;
});

const columnHeight = computed(() => visibleMinutes.value * MINUTE_HEIGHT);

const timeTicks = computed(() => {
  const ticks = [];

  for (
    let minute = visibleWindow.value.startMinute;
    minute <= visibleWindow.value.endMinute;
    minute += 60
  ) {
    ticks.push({
      label: formatTimeLabel(minute),
      minute,
    });
  }

  return ticks;
});

const monthDays = computed(() =>
  buildDayListForView('month', props.anchorDate)
);
const listDays = computed(() => buildDayListForView('list', props.anchorDate));

const columnById = computed(() => {
  return columns.value.reduce((result, column) => {
    result[column.id] = column;
    return result;
  }, {});
});

const monthAppointments = computed(() => {
  return monthDays.value.reduce((result, day) => {
    result[formatDateKey(day)] = props.appointments
      .filter(appointment => {
        const startsAt = toDate(appointment.startsAt);
        const endsAt = toDate(appointment.endsAt);
        return startsAt <= day && endsAt >= day;
      })
      .sort(
        (left, right) => new Date(left.startsAt) - new Date(right.startsAt)
      );
    return result;
  }, {});
});

const listAppointments = computed(() => {
  return listDays.value.map(day => ({
    appointments: props.appointments
      .filter(appointment => {
        return formatDateKey(appointment.startsAt) === formatDateKey(day);
      })
      .sort(
        (left, right) => new Date(left.startsAt) - new Date(right.startsAt)
      ),
    day,
    key: formatDateKey(day),
  }));
});

const timelineNow = computed(() => {
  if (!isTimelineView.value) return null;

  const now = new Date();
  const nowMinute = minuteOfDayFromDate(now);
  const nowKey = formatDateKey(now);

  if (
    nowMinute < visibleWindow.value.startMinute ||
    nowMinute > visibleWindow.value.endMinute
  ) {
    return null;
  }

  return {
    dateKey: nowKey,
    top: (nowMinute - visibleWindow.value.startMinute) * MINUTE_HEIGHT,
  };
});

const hasResources = computed(() => props.resources.length > 0);

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

const hasHolidayForDay = day => {
  return props.holidays.some(holiday => dayMatchesHoliday(holiday, day));
};

const formatMonthDayLabel = day => {
  if (day.getDate() === 1) {
    return day.toLocaleDateString(undefined, {
      day: 'numeric',
      month: 'short',
    });
  }

  return day.toLocaleDateString(undefined, {
    day: 'numeric',
  });
};

const durationForColumn = column => {
  const resource = props.resources.find(item => item.id === column.resourceId);
  return Number(resource?.slotDurationMin || 30);
};

const setColumnRef = (columnId, element) => {
  if (!element) {
    delete columnRefs.value[columnId];
    return;
  }

  columnRefs.value[columnId] = element;
};

const columnElement = columnId => columnRefs.value[columnId];

const appointmentStyle = appointment => {
  const top =
    (minuteOfDayFromDate(appointment.startsAt) -
      visibleWindow.value.startMinute) *
    MINUTE_HEIGHT;
  const height = Math.max(
    MIN_APPOINTMENT_MINUTES * MINUTE_HEIGHT,
    appointment.durationMin * MINUTE_HEIGHT
  );

  return {
    height: `${height}px`,
    top: `${top}px`,
  };
};

const overlayStyle = interval => {
  const top =
    (interval.startMinute - visibleWindow.value.startMinute) * MINUTE_HEIGHT;
  const height = Math.max(
    4,
    (interval.endMinute - interval.startMinute) * MINUTE_HEIGHT
  );

  return {
    height: `${height}px`,
    top: `${top}px`,
  };
};

const holidayForColumn = column => {
  return props.holidays.find(holiday =>
    dayMatchesHoliday(holiday, column.date)
  );
};

const breakIntervalsForColumn = column => {
  return buildBreakIntervals(
    props.breakRules,
    props.workdayOverrides,
    column
  ).filter(interval => {
    return interval.endMinute > visibleWindow.value.startMinute;
  });
};

const timeOffIntervalsForColumn = column => {
  return buildTimeOffIntervals(props.timeOffs, column).filter(interval => {
    return interval.endMinute > visibleWindow.value.startMinute;
  });
};

const appointmentsForColumn = column => {
  return getAppointmentsForColumn(props.appointments, column);
};

const defaultSlotForDay = day => {
  const startsAt = new Date(day);
  startsAt.setHours(9, 0, 0, 0);

  const endsAt = new Date(startsAt);
  endsAt.setMinutes(endsAt.getMinutes() + 30);

  return {
    endsAt: endsAt.toISOString(),
    resourceId: props.resources[0]?.id || '',
    startsAt: startsAt.toISOString(),
  };
};

const minuteFromPointer = (columnId, clientY) => {
  const element = columnElement(columnId);
  if (!element) return visibleWindow.value.startMinute;

  const rect = element.getBoundingClientRect();
  const offsetY = clampMinute(
    Math.max(0, Math.min(clientY - rect.top, rect.height))
  );

  return snapMinute(visibleWindow.value.startMinute + offsetY / MINUTE_HEIGHT);
};

const minuteToIso = (column, minute) => {
  const nextDate = new Date(column.date);
  nextDate.setHours(0, 0, 0, 0);
  nextDate.setMinutes(Math.floor(minute), 0, 0);
  return nextDate.toISOString();
};

const findColumnFromEvent = event => {
  const target = document
    .elementFromPoint(event.clientX, event.clientY)
    ?.closest('[data-scheduling-column-id]');

  if (!target) return null;
  return columnById.value[target.dataset.schedulingColumnId] || null;
};

function handlePointerMove(event) {
  if (!interaction.value) return;

  if (interaction.value.mode === 'create') {
    const minute = minuteFromPointer(interaction.value.columnId, event.clientY);
    interaction.value = {
      ...interaction.value,
      endMinute:
        Math.abs(minute - interaction.value.startMinute) <
        MIN_APPOINTMENT_MINUTES
          ? interaction.value.startMinute + interaction.value.duration
          : minute,
    };
    return;
  }

  if (interaction.value.mode === 'drag') {
    const targetColumn = findColumnFromEvent(event);
    if (!targetColumn) return;

    const pointerMinute = minuteFromPointer(targetColumn.id, event.clientY);
    const unclampedStart = pointerMinute - interaction.value.dragOffsetMinute;
    const maxStart = 24 * 60 - interaction.value.duration;
    const startMinute = snapMinute(
      Math.max(0, Math.min(unclampedStart, maxStart))
    );

    interaction.value = {
      ...interaction.value,
      endMinute: startMinute + interaction.value.duration,
      startMinute,
      targetColumnId: targetColumn.id,
    };
    return;
  }

  if (interaction.value.mode === 'resize') {
    const minute = minuteFromPointer(interaction.value.columnId, event.clientY);
    interaction.value = {
      ...interaction.value,
      endMinute: Math.max(
        interaction.value.startMinute + MIN_APPOINTMENT_MINUTES,
        minute
      ),
    };
  }
}

function clearInteraction() {
  interaction.value = null;
  window.removeEventListener('pointermove', handlePointerMove);
  window.removeEventListener('pointerup', handlePointerUp);
}

handlePointerUp = () => {
  if (!interaction.value) return;

  const currentInteraction = interaction.value;
  const column = columnById.value[currentInteraction.targetColumnId];

  if (!column) {
    clearInteraction();
    return;
  }

  const normalizedStart = Math.min(
    currentInteraction.startMinute,
    currentInteraction.endMinute
  );
  const normalizedEnd = Math.max(
    currentInteraction.startMinute,
    currentInteraction.endMinute
  );

  if (currentInteraction.mode === 'create') {
    emit('createAppointment', {
      endsAt: minuteToIso(
        column,
        normalizedEnd ||
          normalizedStart + currentInteraction.duration ||
          normalizedStart + 30
      ),
      resourceId: column.resourceId,
      startsAt: minuteToIso(column, normalizedStart),
    });
  }

  if (currentInteraction.mode === 'drag') {
    emit('moveAppointment', {
      appointment: currentInteraction.appointment,
      endsAt: minuteToIso(
        column,
        normalizedStart + currentInteraction.duration
      ),
      resourceId: column.resourceId,
      startsAt: minuteToIso(column, normalizedStart),
    });
  }

  if (currentInteraction.mode === 'resize') {
    emit('resizeAppointment', {
      appointment: currentInteraction.appointment,
      endsAt: minuteToIso(column, normalizedEnd),
      startsAt: currentInteraction.appointment.startsAt,
    });
  }

  clearInteraction();
};

const startListening = () => {
  window.addEventListener('pointermove', handlePointerMove);
  window.addEventListener('pointerup', handlePointerUp);
};

const handleCreateStart = (column, event) => {
  if (!hasResources.value) return;

  const minute = minuteFromPointer(column.id, event.clientY);
  const duration = durationForColumn(column);
  interaction.value = {
    columnId: column.id,
    duration,
    endMinute: minute + duration,
    mode: 'create',
    startMinute: minute,
    targetColumnId: column.id,
  };
  startListening();
};

const handleDragStart = (appointment, event) => {
  if (props.view === 'month' || props.view === 'list') return;

  const sourceColumn = columns.value.find(column => {
    return (
      column.resourceId === appointment.resourceId &&
      column.dateKey === formatDateKey(appointment.startsAt)
    );
  });

  if (!sourceColumn) return;

  const pointerMinute = minuteFromPointer(sourceColumn.id, event.clientY);
  const startMinute = minuteOfDayFromDate(appointment.startsAt);
  interaction.value = {
    appointment,
    columnId: sourceColumn.id,
    dragOffsetMinute: pointerMinute - startMinute,
    duration: appointment.durationMin,
    endMinute: minuteOfDayFromDate(appointment.endsAt),
    mode: 'drag',
    startMinute,
    targetColumnId: sourceColumn.id,
  };
  startListening();
};

const handleResizeStart = (appointment, event) => {
  const sourceColumn = columns.value.find(column => {
    return (
      column.resourceId === appointment.resourceId &&
      column.dateKey === formatDateKey(appointment.startsAt)
    );
  });

  if (!sourceColumn) return;

  interaction.value = {
    appointment,
    columnId: sourceColumn.id,
    endMinute: minuteOfDayFromDate(appointment.endsAt),
    mode: 'resize',
    startMinute: minuteOfDayFromDate(appointment.startsAt),
    targetColumnId: sourceColumn.id,
  };
  startListening();
  event.preventDefault();
};

onBeforeUnmount(() => clearInteraction());
</script>

<template>
  <div class="flex flex-col gap-4">
    <div
      v-if="!resources.length"
      class="px-4 py-10 text-sm text-center rounded-2xl outline outline-1 outline-dashed outline-n-strong text-n-slate-11 bg-n-alpha-black2"
    >
      {{ $t('SCHEDULING.CALENDAR.NO_RESOURCES') }}
    </div>

    <template v-else-if="isMonthView">
      <div
        class="grid grid-cols-7 gap-px overflow-hidden rounded-2xl bg-n-weak"
      >
        <div
          v-for="day in monthDays"
          :key="formatDateKey(day)"
          class="flex flex-col min-h-[11rem] bg-n-solid-2"
        >
          <button
            type="button"
            class="sticky top-0 flex items-center justify-between px-3 py-2 text-xs font-semibold border-b bg-n-surface-2 border-n-weak text-n-slate-11"
            @click="emit('createAppointment', defaultSlotForDay(day))"
          >
            <span>{{ formatMonthDayLabel(day) }}</span>
            <span
              v-if="hasHolidayForDay(day)"
              class="i-lucide-flag text-n-ruby-11"
            />
          </button>
          <div class="flex flex-col gap-2 p-2">
            <button
              v-for="appointment in monthAppointments[
                formatDateKey(day)
              ]?.slice(0, 4) || []"
              :key="appointment.id"
              type="button"
              class="flex items-center justify-between gap-2 px-2 py-1 text-xs rounded-lg text-start bg-n-alpha-2 hover:bg-n-alpha-3"
              @click="emit('selectAppointment', appointment)"
            >
              <span class="truncate font-medium text-n-slate-12">
                {{ appointment.clientName }}
              </span>
              <span class="text-n-slate-10">
                {{ formatTimeLabel(minuteOfDayFromDate(appointment.startsAt)) }}
              </span>
            </button>
            <span
              v-if="(monthAppointments[formatDateKey(day)] || []).length > 4"
              class="px-2 text-xs text-n-slate-10"
            >
              {{
                $t('SCHEDULING.CALENDAR.MORE_APPOINTMENTS', {
                  count: monthAppointments[formatDateKey(day)].length - 4,
                })
              }}
            </span>
          </div>
        </div>
      </div>
    </template>

    <template v-else-if="isListView">
      <div class="flex flex-col gap-4">
        <section
          v-for="day in listAppointments"
          :key="day.key"
          class="overflow-hidden rounded-2xl outline outline-1 outline-n-container bg-n-solid-2"
        >
          <header
            class="px-4 py-3 text-sm font-semibold border-b bg-n-surface-2 border-n-weak text-n-slate-12"
          >
            {{ day.key }}
          </header>
          <div
            v-if="day.appointments.length === 0"
            class="px-4 py-6 text-sm text-n-slate-11"
          >
            {{ $t('SCHEDULING.CALENDAR.NO_APPOINTMENTS_DAY') }}
          </div>
          <div v-else class="divide-y divide-n-weak">
            <button
              v-for="appointment in day.appointments"
              :key="appointment.id"
              type="button"
              class="grid items-center w-full grid-cols-[120px_1fr_140px_120px] gap-3 px-4 py-3 text-sm text-start hover:bg-n-alpha-1"
              @click="emit('selectAppointment', appointment)"
            >
              <span class="font-medium text-n-slate-12">
                {{ formatTimeLabel(minuteOfDayFromDate(appointment.startsAt)) }}
              </span>
              <div class="flex flex-col min-w-0">
                <span class="truncate font-medium text-n-slate-12">
                  {{ appointment.clientName }}
                </span>
                <span class="truncate text-xs text-n-slate-11">
                  {{
                    appointment.serviceNameSnapshot ||
                    t('SCHEDULING.CALENDAR.NO_SERVICE')
                  }}
                </span>
              </div>
              <span class="text-xs text-n-slate-11">
                {{ appointmentStatusLabel(appointment.status) }}
              </span>
              <span class="text-xs text-n-slate-11">
                {{ paymentStatusLabel(appointment.paymentStatus) }}
              </span>
            </button>
          </div>
        </section>
      </div>
    </template>

    <template v-else>
      <div
        class="grid grid-cols-[72px_1fr] overflow-hidden rounded-2xl outline outline-1 outline-n-container bg-n-solid-2"
      >
        <div class="sticky left-0 z-10 border-r bg-n-surface-2 border-n-weak">
          <div
            class="sticky top-0 h-[4.25rem] border-b bg-n-surface-2 border-n-weak"
          />
          <div class="relative" :style="{ height: `${columnHeight}px` }">
            <div
              v-for="tick in timeTicks"
              :key="tick.minute"
              class="absolute inset-x-0 flex items-start justify-end pr-3 text-[11px] text-n-slate-10"
              :style="{
                top: `${(tick.minute - visibleWindow.startMinute) * MINUTE_HEIGHT - 7}px`,
              }"
            >
              {{ tick.label }}
            </div>
          </div>
        </div>

        <div class="overflow-x-auto">
          <div
            class="grid min-w-full"
            :style="{
              gridTemplateColumns: `repeat(${columns.length}, minmax(220px, 1fr))`,
            }"
          >
            <div
              v-for="column in columns"
              :key="column.id"
              class="border-l first:border-l-0 border-n-weak"
            >
              <div
                class="sticky top-0 z-10 flex flex-col gap-1 px-3 py-3 border-b bg-n-surface-2 border-n-weak"
              >
                <span
                  class="text-xs font-semibold tracking-wide uppercase text-n-slate-10"
                >
                  {{ formatDateKey(column.date) }}
                </span>
                <span class="text-sm font-medium text-n-slate-12">
                  {{ column.resourceName }}
                </span>
                <span
                  v-if="holidayForColumn(column)"
                  class="text-xs text-n-ruby-11"
                >
                  {{ holidayForColumn(column).title }}
                </span>
              </div>

              <div
                :ref="element => setColumnRef(column.id, element)"
                class="relative"
                :data-scheduling-column-id="column.id"
                :style="{ height: `${columnHeight}px` }"
                @pointerdown.self="handleCreateStart(column, $event)"
              >
                <div
                  v-for="tick in timeTicks"
                  :key="`${column.id}-${tick.minute}`"
                  class="absolute inset-x-0 border-t border-dashed pointer-events-none border-n-weak"
                  :style="{
                    top: `${(tick.minute - visibleWindow.startMinute) * MINUTE_HEIGHT}px`,
                  }"
                />

                <div
                  v-if="
                    holidayForColumn(column) &&
                    !holidayForColumn(column).workingDayOverride
                  "
                  class="absolute inset-0 bg-n-ruby-3/30"
                />

                <div
                  v-for="interval in breakIntervalsForColumn(column)"
                  :key="`${column.id}-break-${interval.startMinute}-${interval.endMinute}`"
                  class="absolute inset-x-0 mx-1 rounded-lg bg-n-amber-5/30 ring-1 ring-n-amber-8/30"
                  :style="overlayStyle(interval)"
                />

                <div
                  v-for="interval in timeOffIntervalsForColumn(column)"
                  :key="`${column.id}-time-off-${interval.startMinute}-${interval.endMinute}`"
                  class="absolute inset-x-0 mx-1 rounded-lg bg-n-ruby-5/25 ring-1 ring-n-ruby-8/30"
                  :style="overlayStyle(interval)"
                />

                <div
                  v-if="timelineNow && timelineNow.dateKey === column.dateKey"
                  class="absolute inset-x-0 z-20 flex items-center gap-1 pointer-events-none"
                  :style="{ top: `${timelineNow.top}px` }"
                >
                  <span class="size-2 rounded-full bg-n-ruby-9" />
                  <div class="flex-1 h-px bg-n-ruby-9" />
                </div>

                <div
                  v-if="interaction && interaction.targetColumnId === column.id"
                  class="absolute inset-x-1 z-20 rounded-xl ring-2 ring-n-brand/40 bg-n-brand/20"
                  :style="
                    overlayStyle({
                      endMinute: Math.max(
                        interaction.startMinute,
                        interaction.endMinute
                      ),
                      startMinute: Math.min(
                        interaction.startMinute,
                        interaction.endMinute
                      ),
                    })
                  "
                />

                <SchedulingAppointmentCard
                  v-for="appointment in appointmentsForColumn(column)"
                  v-show="
                    !(
                      interaction &&
                      interaction.mode === 'drag' &&
                      interaction.appointment.id === appointment.id
                    )
                  "
                  :key="appointment.id"
                  :appointment="appointment"
                  :resource-color="column.resourceColor"
                  :style="appointmentStyle(appointment)"
                  @click="emit('selectAppointment', appointment)"
                  @drag-start="handleDragStart(appointment, $event)"
                  @resize-start="handleResizeStart(appointment, $event)"
                />
              </div>
            </div>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>
