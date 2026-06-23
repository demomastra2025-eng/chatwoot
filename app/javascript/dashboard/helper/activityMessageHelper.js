import { labelDisplayTitle } from './labels';

const EXACT_ACTIVITY_TRANSLATION_KEYS = {
  'Conversation was marked open automatically after an agent reply':
    'CONVERSATION.ACTIVITY.CAPTAIN.AUTO_OPENED_AFTER_AGENT_REPLY',
};

const DEFAULT_POLICY_ASSIGNED_PATTERN =
  /^Политика по умолчанию назначил (?<assigneeName>.+) ответственным$/;
const LEGACY_RU_ASSIGNEE_ASSIGNED_PATTERN =
  /^Назначен ответственный: (?<assigneeName>.+)\. Инициатор: (?<initiatorName>.+)$/;
const LEGACY_EN_ASSIGNEE_ASSIGNED_PATTERN =
  /^Assigned to (?<assigneeName>.+) by (?<initiatorName>.+)$/;
const CURRENT_RU_ASSIGNEE_ASSIGNED_PATTERN =
  /^Назначен: (?<assigneeName>.+)\.\nИнициатор: (?<initiatorName>.+)$/;
const CURRENT_EN_ASSIGNEE_ASSIGNED_PATTERN =
  /^Assigned: (?<assigneeName>.+)\.\nInitiator: (?<initiatorName>.+)$/;
const LABEL_ACTIVITY_PATTERN =
  /^(?<userName>.+?)\s(?<action>добавил|удалил|added|removed)(?<tagPrefix>\s+тег:)?\s+(?<labels>.+)$/u;

const POLICY_SYSTEM_TRANSLATION_KEY =
  'CONVERSATION.ACTIVITY.ASSIGNEE.POLICY_SYSTEM';

const isPolicyInitiator = (initiatorName, translate) => {
  const normalizedName = initiatorName.trim();
  const localizedPolicySystemName = translate(POLICY_SYSTEM_TRANSLATION_KEY);

  return (
    normalizedName === 'Политика по умолчанию' ||
    normalizedName === 'Default Policy' ||
    normalizedName === 'Система политики' ||
    normalizedName === 'Policy system' ||
    normalizedName === localizedPolicySystemName ||
    /^Система автоматизации(?: через .+)?$/.test(normalizedName) ||
    /^Automation System(?: via .+)?$/.test(normalizedName)
  );
};

const normalizePolicyInitiator = (initiatorName, translate) => {
  if (isPolicyInitiator(initiatorName, translate)) {
    return translate(POLICY_SYSTEM_TRANSLATION_KEY);
  }

  return initiatorName.trim();
};

const formatAssignedActivity = (translate, assigneeName, initiatorName) => {
  const normalizedAssigneeName = assigneeName.trim();

  if (isPolicyInitiator(initiatorName, translate)) {
    return translate('CONVERSATION.ACTIVITY.ASSIGNEE.DEFAULT_POLICY_ASSIGNED', {
      assigneeName: normalizedAssigneeName,
    });
  }

  return translate('CONVERSATION.ACTIVITY.ASSIGNEE.ASSIGNED_BY', {
    assigneeName: normalizedAssigneeName,
    initiatorName: normalizePolicyInitiator(initiatorName, translate),
  });
};

const buildLabelTitleMap = labels => {
  if (!Array.isArray(labels)) return new Map();

  return new Map(
    labels.filter(Boolean).flatMap(label => {
      const displayTitle = labelDisplayTitle(label);
      return [
        label?.title ? [label.title, displayTitle] : null,
        displayTitle ? [displayTitle, displayTitle] : null,
      ].filter(Boolean);
    })
  );
};

const formatLabelActivity = ({ userName, action, labels }) => {
  if (action === 'добавил' || action === 'удалил') {
    return `${userName} ${action} тег: ${labels}`;
  }

  return `${userName} ${action} ${labels}`;
};

const replaceActivityLabelTitles = (content, labels) => {
  const labelActivityMatch = content.match(LABEL_ACTIVITY_PATTERN);
  if (!labelActivityMatch?.groups?.labels) return content;

  const labelTitleMap = buildLabelTitleMap(labels);
  const rawLabelTitles = labelActivityMatch.groups.labels
    .split(',')
    .map(labelTitle => labelTitle.trim())
    .filter(Boolean);
  const hasKnownLabel = rawLabelTitles.some(labelTitle =>
    labelTitleMap.has(labelTitle)
  );
  const hasMultipleLabels = rawLabelTitles.length > 1;

  if (
    !labelActivityMatch.groups.tagPrefix &&
    !hasMultipleLabels &&
    !hasKnownLabel
  ) {
    return content;
  }

  const normalizedLabels = rawLabelTitles
    .map(labelTitle => labelTitleMap.get(labelTitle) || labelTitle)
    .join(', ');

  return formatLabelActivity({
    userName: labelActivityMatch.groups.userName,
    action: labelActivityMatch.groups.action,
    labels: normalizedLabels,
  });
};

export const getLocalizedActivityMessage = (
  content,
  translate,
  options = {}
) => {
  if (!content || typeof translate !== 'function') return content;

  const normalizedContent = content.trim();
  const exactTranslationKey =
    EXACT_ACTIVITY_TRANSLATION_KEYS[normalizedContent];
  if (exactTranslationKey) return translate(exactTranslationKey);

  const defaultPolicyMatch = normalizedContent.match(
    DEFAULT_POLICY_ASSIGNED_PATTERN
  );
  if (defaultPolicyMatch?.groups?.assigneeName) {
    return formatAssignedActivity(
      translate,
      defaultPolicyMatch.groups.assigneeName,
      translate(POLICY_SYSTEM_TRANSLATION_KEY)
    );
  }

  const currentAssignedMatch =
    normalizedContent.match(CURRENT_RU_ASSIGNEE_ASSIGNED_PATTERN) ||
    normalizedContent.match(CURRENT_EN_ASSIGNEE_ASSIGNED_PATTERN);
  if (currentAssignedMatch?.groups?.assigneeName) {
    return formatAssignedActivity(
      translate,
      currentAssignedMatch.groups.assigneeName,
      currentAssignedMatch.groups.initiatorName
    );
  }

  const legacyAssignedMatch =
    normalizedContent.match(LEGACY_RU_ASSIGNEE_ASSIGNED_PATTERN) ||
    normalizedContent.match(LEGACY_EN_ASSIGNEE_ASSIGNED_PATTERN);
  if (legacyAssignedMatch?.groups?.assigneeName) {
    return formatAssignedActivity(
      translate,
      legacyAssignedMatch.groups.assigneeName,
      legacyAssignedMatch.groups.initiatorName
    );
  }

  return replaceActivityLabelTitles(content, options.labels);
};
