import { getUnavailableStageColors, pickStageColor } from './stageColors';

export const TASK_STATUS_STANDARD_COLORS = [
  '#F0F0F3',
  '#E8E8EC',
  '#0EA5E9',
  '#3B82F6',
  '#6366F1',
  '#8B5CF6',
  '#A855F7',
  '#EC4899',
  '#F97316',
  '#EAB308',
  '#22C55E',
  '#14B8A6',
];
export const DEFAULT_TASK_STATUS_COLOR = TASK_STATUS_STANDARD_COLORS[0];

export const getUnavailableTaskStatusColors = (
  taskStatuses = [],
  palette = TASK_STATUS_STANDARD_COLORS,
  currentTaskStatusId = null
) => getUnavailableStageColors(taskStatuses, palette, currentTaskStatusId);

export const pickTaskStatusColor = (
  taskStatuses = [],
  palette = TASK_STATUS_STANDARD_COLORS,
  currentTaskStatusId = null
) => pickStageColor(taskStatuses, palette, currentTaskStatusId);
