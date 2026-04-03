<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import SchedulingVueCalCalendar from 'dashboard/components-next/Scheduling/SchedulingVueCalCalendar.vue';

const props = defineProps({
  anchorDate: {
    type: [Date, String],
    required: true,
  },
  canManage: {
    type: Boolean,
    default: false,
  },
  assigneeNames: {
    type: Object,
    default: () => ({}),
  },
  fieldDefinitions: {
    type: Array,
    default: () => [],
  },
  dealNames: {
    type: Object,
    default: () => ({}),
  },
  statusNames: {
    type: Object,
    default: () => ({}),
  },
  tasks: {
    type: Array,
    default: () => [],
  },
  view: {
    type: String,
    required: true,
  },
});

const emit = defineEmits([
  'createTask',
  'moveTask',
  'resizeTask',
  'selectTask',
]);
const { t } = useI18n();

const priorityColor = priority => {
  const colors = {
    high: '#D97706',
    low: '#0F766E',
    medium: '#2563EB',
    urgent: '#DC2626',
  };

  return colors[priority] || '#2563EB';
};

const resolveTaskRange = task => {
  const startValue = task.startAt || task.dueAt;
  const endValue = task.dueAt || task.startAt;

  if (!startValue && !endValue) {
    return null;
  }

  const startsAt = new Date(startValue || endValue);
  if (Number.isNaN(startsAt.getTime())) {
    return null;
  }

  let endsAt = endValue ? new Date(endValue) : new Date(startsAt);
  if (Number.isNaN(endsAt.getTime()) || endsAt <= startsAt) {
    endsAt = new Date(startsAt.getTime() + 60 * 60 * 1000);
  }

  return { endsAt, startsAt };
};

const buildTaskSubtitle = task => {
  return [
    props.statusNames[task.statusId],
    props.dealNames[task.dealId],
    props.assigneeNames[task.assigneeId],
  ]
    .filter(Boolean)
    .join(' · ');
};

const calendarTasks = computed(() =>
  props.tasks
    .map(task => {
      const range = resolveTaskRange(task);
      if (!range) {
        return null;
      }

      return {
        id: task.id,
        startsAt: range.startsAt.toISOString(),
        endsAt: range.endsAt.toISOString(),
        status: task.archivedAt ? 'cancelled' : 'scheduled',
        statusIcon: task.archivedAt ? 'i-lucide-archive' : 'i-lucide-list-todo',
        statusLabel: task.archivedAt
          ? t('CRM.GENERAL.ARCHIVED')
          : props.statusNames[task.statusId] || t('CRM.GENERAL.EMPTY_VALUE'),
        title: task.title,
        subtitle: buildTaskSubtitle(task),
        clientName: task.title,
        customAttributes: task.customAttributes,
        serviceNameSnapshot: buildTaskSubtitle(task),
        resourceColor: priorityColor(task.priority),
        resourceName: '',
        muted: Boolean(task.archivedAt),
        cancelled: Boolean(task.archivedAt),
        task,
      };
    })
    .filter(Boolean)
);

const handleSelectTask = appointment => {
  emit('selectTask', appointment.task || appointment);
};

const handleCreateTask = payload => {
  emit('createTask', payload);
};

const handleMoveTask = payload => {
  emit('moveTask', {
    ...payload,
    task: payload.appointment?.task || payload.appointment,
  });
};

const handleResizeTask = payload => {
  emit('resizeTask', {
    ...payload,
    task: payload.appointment?.task || payload.appointment,
  });
};
</script>

<template>
  <SchedulingVueCalCalendar
    class="min-h-0 flex-1"
    :anchor-date="anchorDate"
    :appointments="calendarTasks"
    :allow-create-without-resources="canManage"
    :break-rules="[]"
    :custom-field-definitions="fieldDefinitions"
    :holidays="[]"
    :read-only="!canManage"
    :resources="[]"
    :slots="[]"
    :time-offs="[]"
    :view="view"
    :work-rules="[]"
    :workday-overrides="[]"
    @create-appointment="handleCreateTask"
    @move-appointment="handleMoveTask"
    @resize-appointment="handleResizeTask"
    @select-appointment="handleSelectTask"
  />
</template>
