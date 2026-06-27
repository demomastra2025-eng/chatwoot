<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import CrmCustomFieldsSummary from 'dashboard/components-next/CRM/CrmCustomFieldsSummary.vue';
import {
  buildDayListForView,
  formatDateKey,
} from 'dashboard/routes/dashboard/scheduling/helpers';

import SchedulingKanbanBoard from './SchedulingKanbanBoard.vue';
import SchedulingStatusMenu from './SchedulingStatusMenu.vue';
import SchedulingVueCalCalendar from './SchedulingVueCalCalendar.vue';

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
  emptyMessage: {
    type: String,
    default: '',
  },
  holidays: {
    type: Array,
    default: () => [],
  },
  presentation: {
    type: String,
    default: 'calendar',
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
  'changeStatus',
  'createAppointment',
  'moveAppointment',
  'resizeAppointment',
  'selectAppointment',
]);

const { locale } = useI18n();

const isCalendarView = computed(() => props.presentation === 'calendar');
const isKanbanView = computed(() => props.presentation === 'kanban');
const isListView = computed(() => props.presentation === 'list');
const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);

const listDays = computed(() =>
  buildDayListForView(props.view, props.anchorDate)
);

const getDayRange = day => {
  const start = new Date(day);
  start.setHours(0, 0, 0, 0);

  const end = new Date(start);
  end.setDate(end.getDate() + 1);

  return { end, start };
};

const getAppointmentDisplayRangeForDay = (appointment, day) => {
  const startsAt = new Date(appointment.startsAt);
  const endsAt = new Date(appointment.endsAt);
  const { end, start } = getDayRange(day);

  if (Number.isNaN(startsAt.getTime()) || Number.isNaN(endsAt.getTime())) {
    return null;
  }

  if (startsAt >= end || endsAt <= start) {
    return null;
  }

  return {
    end: endsAt < end ? endsAt : end,
    start: startsAt > start ? startsAt : start,
  };
};

const resourceNamesById = computed(() =>
  props.resources.reduce((result, resource) => {
    result[resource.id] = resource.name;
    return result;
  }, {})
);

const listAppointments = computed(() => {
  return listDays.value
    .map(day => ({
      appointments: props.appointments
        .filter(appointment =>
          getAppointmentDisplayRangeForDay(appointment, day)
        )
        .sort(
          (left, right) =>
            getAppointmentDisplayRangeForDay(left, day).start -
            getAppointmentDisplayRangeForDay(right, day).start
        ),
      day,
      key: formatDateKey(day),
    }))
    .filter(day => day.appointments.length > 0);
});

const formatListDayLabel = day =>
  new Intl.DateTimeFormat(localeCode.value, {
    day: 'numeric',
    month: 'long',
    weekday: 'long',
  }).format(day);

const formatAppointmentDateTime = value =>
  new Intl.DateTimeFormat(localeCode.value, {
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(value));

const formatAppointmentTimeRange = (appointment, day) => {
  const range = getAppointmentDisplayRangeForDay(appointment, day);
  if (!range) return '—';

  return `${formatAppointmentDateTime(range.start)} - ${formatAppointmentDateTime(range.end)}`;
};

const resourceName = resourceId => resourceNamesById.value[resourceId] || '—';

const handleStatusChange = payload => {
  emit('changeStatus', payload);
};
</script>

<template>
  <div class="flex h-full min-h-0 flex-col gap-4">
    <div
      v-if="!resources.length"
      class="px-4 py-10 text-sm text-center rounded-2xl outline outline-1 outline-dashed outline-n-strong text-n-slate-11 bg-n-alpha-black2"
    >
      {{ emptyMessage || $t('SCHEDULING.CALENDAR.NO_RESOURCES') }}
    </div>

    <template v-else-if="isCalendarView">
      <SchedulingVueCalCalendar
        class="min-h-0 flex-1"
        :anchor-date="anchorDate"
        :appointments="appointments"
        :break-rules="breakRules"
        :custom-field-definitions="customFieldDefinitions"
        :holidays="holidays"
        :resources="resources"
        :slots="slots"
        :time-offs="timeOffs"
        :view="view"
        :work-rules="workRules"
        :workday-overrides="workdayOverrides"
        @create-appointment="emit('createAppointment', $event)"
        @move-appointment="emit('moveAppointment', $event)"
        @resize-appointment="emit('resizeAppointment', $event)"
        @select-appointment="emit('selectAppointment', $event)"
      />
    </template>

    <template v-else-if="isListView">
      <div v-if="listAppointments.length" class="flex flex-col gap-4">
        <section
          v-for="day in listAppointments"
          :key="day.key"
          class="overflow-hidden rounded-2xl outline outline-1 outline-n-container bg-n-solid-2"
        >
          <header
            class="px-4 py-3 text-sm font-semibold border-b bg-n-surface-2 border-n-weak text-n-slate-12"
          >
            {{ formatListDayLabel(day.day) }}
          </header>
          <div
            v-if="day.appointments.length === 0"
            class="px-4 py-6 text-sm text-n-slate-11"
          >
            {{ $t('SCHEDULING.CALENDAR.NO_APPOINTMENTS_DAY') }}
          </div>
          <div v-else class="divide-y divide-n-weak">
            <div
              v-for="appointment in day.appointments"
              :key="appointment.id"
              class="grid gap-3 px-4 py-3 hover:bg-n-alpha-1 md:grid-cols-[110px_minmax(0,1fr)_auto] md:items-start"
            >
              <button
                type="button"
                class="grid min-w-0 items-start gap-3 text-left md:col-span-2 md:grid-cols-[110px_minmax(0,1fr)]"
                @click="emit('selectAppointment', appointment)"
              >
                <span class="pt-0.5 font-medium text-n-slate-12">
                  {{ formatAppointmentTimeRange(appointment, day.day) }}
                </span>
                <div class="flex min-w-0 flex-col gap-1">
                  <span
                    class="font-medium whitespace-normal break-words text-n-slate-12"
                  >
                    {{ appointment.clientName }}
                  </span>
                  <span
                    class="text-xs whitespace-normal break-words text-n-slate-11"
                  >
                    {{
                      [
                        appointment.serviceNameSnapshot,
                        resourceName(appointment.resourceId),
                      ]
                        .filter(Boolean)
                        .join(' · ')
                    }}
                  </span>
                  <CrmCustomFieldsSummary
                    :definitions="customFieldDefinitions"
                    :values="appointment.customAttributes"
                    :max-items="2"
                    :truncate="false"
                  />
                </div>
              </button>

              <div
                class="flex justify-start md:self-start md:justify-end"
                @click.stop
              >
                <SchedulingStatusMenu
                  :model-value="appointment.status"
                  @update:model-value="
                    handleStatusChange({ appointment, status: $event })
                  "
                />
              </div>
            </div>
          </div>
        </section>
      </div>
      <div
        v-else
        class="px-4 py-6 text-sm rounded-2xl outline outline-1 outline-n-container bg-n-solid-2 text-n-slate-11"
      >
        {{ $t('SCHEDULING.CALENDAR.NO_APPOINTMENTS_DAY') }}
      </div>
    </template>

    <template v-else-if="isKanbanView">
      <div class="flex min-h-0 flex-1 flex-col">
        <SchedulingKanbanBoard
          class="min-h-0 flex-1"
          :appointments="appointments"
          :custom-field-definitions="customFieldDefinitions"
          :resources="resources"
          @change-status="handleStatusChange"
          @select-appointment="emit('selectAppointment', $event)"
        />
      </div>
    </template>

    <template v-else>
      <div
        class="flex items-center justify-center py-10 text-sm text-n-slate-11"
      >
        {{ $t('SCHEDULING.GENERAL.NO_DATA') }}
      </div>
    </template>
  </div>
</template>
