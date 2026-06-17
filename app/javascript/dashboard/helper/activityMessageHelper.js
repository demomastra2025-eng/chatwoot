const EXACT_ACTIVITY_TRANSLATION_KEYS = {
  'Conversation was marked open automatically after an agent reply':
    'CONVERSATION.ACTIVITY.CAPTAIN.AUTO_OPENED_AFTER_AGENT_REPLY',
};

const DEFAULT_POLICY_ASSIGNED_PATTERN =
  /^Политика по умолчанию назначил (?<assigneeName>.+) ответственным$/;

export const getLocalizedActivityMessage = (content, translate) => {
  if (!content || typeof translate !== 'function') return content;

  const normalizedContent = content.trim();
  const exactTranslationKey =
    EXACT_ACTIVITY_TRANSLATION_KEYS[normalizedContent];
  if (exactTranslationKey) return translate(exactTranslationKey);

  const defaultPolicyMatch = normalizedContent.match(
    DEFAULT_POLICY_ASSIGNED_PATTERN
  );
  if (defaultPolicyMatch?.groups?.assigneeName) {
    return translate('CONVERSATION.ACTIVITY.ASSIGNEE.DEFAULT_POLICY_ASSIGNED', {
      assigneeName: defaultPolicyMatch.groups.assigneeName,
    });
  }

  return content;
};
