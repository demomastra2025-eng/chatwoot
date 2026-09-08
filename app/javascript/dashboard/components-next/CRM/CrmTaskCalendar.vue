<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import SchedulingVueCalCalendar from 'dashboard/components-next/Scheduling/SchedulingVueCalCalendar.vue';
import { taskDueDate } from 'dashboard/routes/dashboard/crm/taskTimeBuckets';

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

const activityTypeLabelByValue = computed(() => ({
  call: t('CRM.TASKS.ACTIVITY_TYPE.call'),
  meeting: t('CRM.TASKS.ACTIVITY_TYPE.meeting'),
  message: t('CRM.TASKS.ACTIVITY_TYPE.message'),
  task: t('CRM.TASKS.ACTIVITY_TYPE.task'),
  touch: t('CRM.TASKS.ACTIVITY_TYPE.touch'),
}));

const activityTypeLabel = task =>
  activityTypeLabelByValue.value[task.activityType || 'task'] ||
  task.activityType;

const resolveTaskRange = task => {
  if (task.allDay) {
    const dueDate = taskDueDate(task);
    if (!dueDate) return null;

    const startsAt = new Date(dueDate);
    const endsAt = new Date(dueDate);
    startsAt.setHours(0, 0, 0, 0);
    endsAt.setHours(23, 59, 59, 999);
    return { endsAt, startsAt };
  }

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
    activityTypeLabel(task),
    props.dealNames[task.dealId],
    props.assigneeNames[task.assigneeId],
  ]
    .filter(Boolean)
    .join(' · ');
};

const isOverdue = task => {
  const dueDate = taskDueDate(task);
  if (!dueDate) return false;
  if (!task.allDay) return dueDate < new Date();

  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return dueDate < today;
};

const calendarTasks = computed(() =>
  props.tasks
    .filter(task => !task.archivedAt && !task.completedAt && !task.cancelledAt)
    .map(task => {
      const range = resolveTaskRange(task);
      if (!range) {
        return null;
      }

      const overdue = isOverdue(task);

      return {
        allDay: Boolean(task.allDay),
        id: task.id,
        startsAt: range.startsAt.toISOString(),
        endsAt: range.endsAt.toISOString(),
        hideStatus: !overdue,
        status: 'scheduled',
        statusIcon: 'i-lucide-circle-alert',
        statusLabel: overdue ? t('CRM.TASKS.BOARD.OVERDUE_BADGE') : '',
        title: task.title,
        subtitle: buildTaskSubtitle(task),
        clientName: task.title,
        customAttributes: task.customAttributes,
        serviceNameSnapshot: buildTaskSubtitle(task),
        resourceColor: '#2563EB',
        resourceName: '',
        muted: false,
        cancelled: false,
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
    all-day-events
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
