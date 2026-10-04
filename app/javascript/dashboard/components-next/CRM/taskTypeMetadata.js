import { normalizeCrmTaskTypeIcon } from './taskTypeIcons';

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

// Build once per catalogue/locale change, then resolve each row in O(1).
export const buildTaskTypeResolver = (taskTypes, t) => {
  const legacy = new Map(
    Object.entries(legacyIcons).map(([code, icon]) => [
      code,
      { icon, label: t(legacyTranslationKeys[code]) },
    ])
  );
  const metadata = type => ({
    icon: normalizeCrmTaskTypeIcon(type.icon || legacy.get(type.code)?.icon),
    label:
      type.name ||
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
      legacy.get(code) || { icon: legacyIcons.task, label: code }
    );
  };
};
