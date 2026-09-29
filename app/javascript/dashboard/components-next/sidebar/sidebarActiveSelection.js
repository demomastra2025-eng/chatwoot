const ASSIGNEE_ITEM_PREFIX = 'Assignee:';

export const resolveRouteConversationAssigneeType = (query = {}) =>
  query.assignee_type ?? query.assigneeType ?? 'all';

export const hasExclusiveConversationScope = ({
  label,
  teamId,
  foldersId,
  query = {},
}) =>
  Boolean(
    label ||
      teamId ||
      foldersId ||
      query.crm_stage_id ||
      query.crmStageId ||
      query.appointment_status ||
      query.appointmentStatus ||
      query.labels_scope ||
      query.labelsScope ||
      query.team_scope ||
      query.teamScope
  );

export const resolveConversationAssigneeType = ({
  requestedType,
  allowedTypes,
  allType,
  isLocked = false,
  hasExclusiveScope = false,
}) => {
  if (isLocked || hasExclusiveScope) return allType;
  return allowedTypes.includes(requestedType) ? requestedType : allType;
};

export const selectExclusiveSidebarChildNames = activeNames => {
  const names = activeNames.filter(Boolean);
  const scopedNames = names.filter(
    name => !name.startsWith(ASSIGNEE_ITEM_PREFIX)
  );

  if (scopedNames.length) {
    return [scopedNames[scopedNames.length - 1]];
  }

  return names.slice(0, 1);
};
