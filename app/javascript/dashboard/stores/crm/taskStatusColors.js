import {
  DEFAULT_STAGE_COLOR,
  STAGE_STANDARD_COLORS,
  getUnavailableStageColors,
  pickStageColor,
} from './stageColors';

export const TASK_STATUS_STANDARD_COLORS = STAGE_STANDARD_COLORS;
export const DEFAULT_TASK_STATUS_COLOR = DEFAULT_STAGE_COLOR;

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
