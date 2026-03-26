export const CALENDAR_STORAGE_KEY = 'onelink:scheduling:calendar-preferences';

export const SCHEDULING_VIEW_ORDER = ['day', 'week', 'month', 'list', 'kanban'];

export const SCHEDULING_VIEWS = [
  { value: 'day', labelKey: 'SCHEDULING.VIEWS.DAY' },
  { value: 'week', labelKey: 'SCHEDULING.VIEWS.WEEK' },
  { value: 'month', labelKey: 'SCHEDULING.VIEWS.MONTH' },
  { value: 'list', labelKey: 'SCHEDULING.VIEWS.LIST' },
  { value: 'kanban', labelKey: 'SCHEDULING.VIEWS.KANBAN' },
];

export const APPOINTMENT_STATUS_VALUES = [
  'scheduled',
  'confirmed',
  'completed',
  'cancelled',
  'no_show',
];

export const APPOINTMENT_STATUS_ICONS = {
  scheduled: 'i-lucide-clock-3',
  confirmed: 'i-lucide-badge-check',
  completed: 'i-lucide-check-check',
  cancelled: 'i-lucide-circle-off',
  no_show: 'i-lucide-user-round-x',
};

export const PAYMENT_STATUS_VALUES = [
  'awaiting_payment',
  'prepaid',
  'paid',
  'cancelled',
];

export const PAYMENT_METHOD_VALUES = [
  'kaspi_transfer',
  'kaspi_qr',
  'cash',
  'bank_transfer',
  'card',
  'other',
];

export const PAYMENT_KIND_VALUES = ['prepaid', 'payment', 'adjustment'];

export const APPOINTMENT_TYPE_VALUES = ['primary', 'secondary', 'other'];

export const EXPENSE_STATUS_VALUES = ['unpaid', 'paid'];

export const COMPENSATION_TYPE_VALUES = [
  'percent',
  'fixed',
  'fixed_plus_percent',
];

export const WEEKDAY_VALUES = [1, 2, 3, 4, 5, 6, 0];

export const DEFAULT_VISIBLE_START_MINUTE = 7 * 60;
export const DEFAULT_VISIBLE_END_MINUTE = 22 * 60;
export const MINUTE_STEP = 5;
export const HOUR_ROW_HEIGHT = 100;
export const MINUTE_HEIGHT = HOUR_ROW_HEIGHT / 60;
export const MIN_APPOINTMENT_MINUTES = 5;
export const SIDEBAR_DATE_FORMAT = 'EEE, d MMM';

export const RESOURCE_COLORS = [
  '#0EA5E9',
  '#3B82F6',
  '#6366F1',
  '#8B5CF6',
  '#A855F7',
  '#D946EF',
  '#EC4899',
  '#F43F5E',
  '#EF4444',
  '#F97316',
  '#F59E0B',
  '#EAB308',
  '#84CC16',
  '#22C55E',
  '#10B981',
  '#14B8A6',
  '#06B6D4',
];
