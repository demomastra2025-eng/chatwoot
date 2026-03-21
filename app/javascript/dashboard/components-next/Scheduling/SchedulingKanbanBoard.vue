<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';

import SchedulingStatusMenu from './SchedulingStatusMenu.vue';
import { APPOINTMENT_STATUS_ICONS } from 'dashboard/routes/dashboard/scheduling/constants';

const props = defineProps({
  appointments: {
    type: Array,
    default: () => [],
  },
  resources: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['changeStatus', 'selectAppointment']);
const { t, locale } = useI18n();

const statusOrder = [
  'scheduled',
  'confirmed',
  'completed',
  'no_show',
  'cancelled',
];
const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);

const statusMeta = computed(() => ({
  cancelled: {
    icon: APPOINTMENT_STATUS_ICONS.cancelled,
    label: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
  },
  completed: {
    icon: APPOINTMENT_STATUS_ICONS.completed,
    label: t('SCHEDULING.APPOINTMENT_STATUS.completed'),
  },
  confirmed: {
    icon: APPOINTMENT_STATUS_ICONS.confirmed,
    label: t('SCHEDULING.APPOINTMENT_STATUS.confirmed'),
  },
  no_show: {
    icon: APPOINTMENT_STATUS_ICONS.no_show,
    label: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
  },
  scheduled: {
    icon: APPOINTMENT_STATUS_ICONS.scheduled,
    label: t('SCHEDULING.APPOINTMENT_STATUS.scheduled'),
  },
}));

const resourceNamesById = computed(() => {
  return props.resources.reduce((result, resource) => {
    result[resource.id] = resource.name;
    return result;
  }, {});
});

const createBoardState = () =>
  statusOrder.reduce((result, status) => {
    result[status] = [];
    return result;
  }, {});

const boardColumns = ref(createBoardState());

const sortedAppointments = appointments =>
  [...appointments].sort(
    (left, right) => new Date(left.startsAt) - new Date(right.startsAt)
  );

const syncBoardColumns = () => {
  const nextColumns = createBoardState();

  sortedAppointments(props.appointments).forEach(appointment => {
    const status = nextColumns[appointment.status]
      ? appointment.status
      : 'scheduled';

    nextColumns[status].push({ ...appointment, status });
  });

  boardColumns.value = nextColumns;
};

watch(
  () => props.appointments,
  () => syncBoardColumns(),
  { deep: true, immediate: true }
);

const kanbanColumns = computed(() =>
  statusOrder.map(status => ({
    appointments: boardColumns.value[status],
    icon: statusMeta.value[status].icon,
    label: statusMeta.value[status].label,
    value: status,
  }))
);

const formatDateLabel = value =>
  new Intl.DateTimeFormat(localeCode.value, {
    day: 'numeric',
    month: 'short',
    weekday: 'short',
  }).format(new Date(value));

const formatTimeLabel = value =>
  new Intl.DateTimeFormat(localeCode.value, {
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(value));

const formatTimeRange = appointment =>
  `${formatTimeLabel(appointment.startsAt)} - ${formatTimeLabel(
    appointment.endsAt
  )}`;

const appointmentSubtitle = appointment => {
  return [
    appointment.serviceNameSnapshot,
    resourceNamesById.value[appointment.resourceId],
  ]
    .filter(Boolean)
    .join(' · ');
};

const emitStatusChange = (appointment, status) => {
  if (!appointment || appointment.status === status) return;

  appointment.status = status;
  emit('changeStatus', { appointment, status });
};

const moveAppointmentToStatus = (appointment, nextStatus) => {
  const currentStatus = statusOrder.find(status =>
    boardColumns.value[status].some(item => item.id === appointment.id)
  );

  if (!currentStatus || currentStatus === nextStatus) return;

  boardColumns.value[currentStatus] = boardColumns.value[currentStatus].filter(
    item => item.id !== appointment.id
  );

  const updatedAppointment = { ...appointment, status: nextStatus };
  boardColumns.value[nextStatus] = [
    updatedAppointment,
    ...boardColumns.value[nextStatus],
  ];

  emit('changeStatus', {
    appointment: updatedAppointment,
    status: nextStatus,
  });
};

const handleColumnChange = (event, status) => {
  if (!event.added) return;

  const appointment = boardColumns.value[status][event.added.newIndex];
  emitStatusChange(appointment, status);
};
</script>

<template>
  <div class="flex h-full min-h-0 flex-col">
    <div class="min-h-0 flex-1 overflow-x-auto overflow-y-hidden px-1 pb-2">
      <div class="flex h-full min-w-max items-stretch gap-4 py-1">
        <section
          v-for="column in kanbanColumns"
          :key="column.value"
          class="flex h-full min-h-0 w-[15rem] shrink-0 flex-col overflow-hidden rounded-2xl outline outline-1 outline-n-container bg-n-solid-2"
        >
          <header
            class="flex items-center justify-between gap-3 border-b border-n-weak bg-n-surface-2 px-4 py-3"
          >
            <div class="flex min-w-0 items-center gap-2">
              <span
                :class="[column.icon, 'size-4 shrink-0 text-n-slate-11']"
                aria-hidden="true"
              />
              <h3 class="mb-0 truncate text-sm font-semibold text-n-slate-12">
                {{ column.label }}
              </h3>
            </div>
            <span
              class="rounded-full bg-n-alpha-black2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
            >
              {{ column.appointments.length }}
            </span>
          </header>

          <Draggable
            :list="boardColumns[column.value]"
            animation="180"
            class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto p-3"
            ghost-class="scheduling-kanban-card-ghost"
            group="scheduling-kanban"
            item-key="id"
            @change="handleColumnChange($event, column.value)"
          >
            <template #item="{ element }">
              <article
                class="rounded-2xl border border-n-weak bg-n-surface-1 p-3 shadow-sm transition-shadow hover:shadow-md"
                @click="emit('selectAppointment', element)"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <h4
                      class="mb-0 truncate text-sm font-semibold text-n-slate-12"
                    >
                      {{ element.clientName }}
                    </h4>
                    <p class="mb-0 mt-1 text-xs text-n-slate-11">
                      {{ appointmentSubtitle(element) }}
                    </p>
                  </div>

                  <SchedulingStatusMenu
                    :model-value="element.status"
                    neutral
                    @update:model-value="
                      moveAppointmentToStatus(element, $event)
                    "
                  />
                </div>

                <div class="mt-3 flex flex-col gap-1 text-xs text-n-slate-11">
                  <span>{{ formatDateLabel(element.startsAt) }}</span>
                  <span>{{ formatTimeRange(element) }}</span>
                </div>
              </article>
            </template>

            <template #footer>
              <div
                v-if="!column.appointments.length"
                class="flex min-h-[8rem] flex-1 items-center justify-center rounded-2xl border border-dashed border-n-strong bg-n-alpha-black2 px-4 text-center text-sm text-n-slate-11"
              >
                {{ $t('SCHEDULING.CALENDAR.NO_APPOINTMENTS_STATUS') }}
              </div>
            </template>
          </Draggable>
        </section>
      </div>
    </div>
  </div>
</template>

<style scoped lang="scss">
.scheduling-kanban-card-ghost {
  @apply opacity-40;
}
</style>
