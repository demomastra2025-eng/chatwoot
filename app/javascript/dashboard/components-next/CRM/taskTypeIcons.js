export const CRM_TASK_TYPE_ICONS = [
  'i-lucide-list-todo',
  'i-lucide-phone',
  'i-lucide-calendar-days',
  'i-lucide-message-square',
  'i-lucide-mail',
  'i-lucide-users',
  'i-lucide-handshake',
  'i-lucide-briefcase-business',
  'i-lucide-clipboard-check',
  'i-lucide-clock-3',
  'i-lucide-bell',
  'i-lucide-check-circle-2',
  'i-lucide-star',
];

export const normalizeCrmTaskTypeIcon = icon =>
  /^i-lucide-[a-z0-9-]+$/.test(icon || '') ? icon : CRM_TASK_TYPE_ICONS[0];
