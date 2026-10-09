import { normalizeCrmTaskTypeIcon } from './taskTypeIcons';
import { taskTypeLabel } from './taskCatalogLabels';

const legacyIcons = {
  call: 'i-lucide-phone',
  meeting: 'i-lucide-users',
  message: 'i-lucide-message-square',
  task: 'i-lucide-list-todo',
  touch: 'i-lucide-handshake',
};

const legacyTranslationKeys = {
  call: 'CRM.TASKS.ACTIVITY_TYPE.call',
  meeting: 'CRM.TASKS.ACTIVITY_TYPE.meeting',
  message: 'CRM.TASKS.ACTIVITY_TYPE.message',
  task: 'CRM.TASKS.ACTIVITY_TYPE.task',
  touch: 'CRM.TASKS.ACTIVITY_TYPE.touch',
};

const taskTypeColors = {
  call: 'text-n-amber-11',
  meeting: 'text-n-iris-11',
  message: 'text-n-blue-11',
  task: 'text-n-teal-11',
  touch: 'text-n-ruby-11',
};

const customTaskTypeColors = [
  'text-n-blue-11',
  'text-n-iris-11',
  'text-n-teal-11',
  'text-n-amber-11',
  'text-n-ruby-11',
];

export const taskTypeColorClass = type => {
  if (taskTypeColors[type?.code]) return taskTypeColors[type.code];

  const key = String(type?.code || type?.id || 'custom');
  const hash = [...key].reduce(
    (result, character) => result + character.charCodeAt(0),
    0
  );
  return customTaskTypeColors[hash % customTaskTypeColors.length];
};

// Build once per catalogue/locale change, then resolve each row in O(1).
export const buildTaskTypeResolver = (taskTypes, t) => {
  const legacy = new Map(
    Object.entries(legacyIcons).map(([code, icon]) => [
      code,
      {
        colorClass: taskTypeColors[code],
        icon,
        label: t(legacyTranslationKeys[code]),
      },
    ])
  );
  const metadata = type => ({
    colorClass: taskTypeColorClass(type),
    icon: normalizeCrmTaskTypeIcon(type.icon || legacy.get(type.code)?.icon),
    label:
      taskTypeLabel(type, t) ||
      legacy.get(type.code)?.label ||
      type.code ||
      legacy.get('task').label,
  });
  const byId = new Map();
  const byCode = new Map();
  taskTypes.forEach(type => {
    const value = metadata(type);
    byId.set(String(type.id), value);
    if (type.code) byCode.set(type.code, value);
  });
  return task => {
    const code = task.activityType || task.taskType?.code || 'task';
    return (
      byId.get(String(task.taskTypeId || task.taskType?.id)) ||
      byCode.get(code) ||
      (task.taskType?.name ? metadata(task.taskType) : null) ||
      legacy.get(code) || {
        colorClass: 'text-n-slate-11',
        icon: legacyIcons.task,
        label: code,
      }
    );
  };
};
