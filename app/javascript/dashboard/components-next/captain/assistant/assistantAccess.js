export const externalAssistants = (assistants = []) =>
  assistants.filter(assistant => assistant.usage_mode !== 'internal_assistant');

export const activeExternalAssistants = (assistants = [], excludeId = null) =>
  externalAssistants(assistants).filter(
    assistant =>
      assistant.active !== false && Number(assistant.id) !== Number(excludeId)
  );

export const normalizeAssistantIds = (ids = []) =>
  [...new Set(ids.map(Number))].filter(id => Number.isInteger(id) && id > 0);

export const knowledgeAssistantIds = material =>
  normalizeAssistantIds(
    material?.allowed_assistant_ids || [
      material?.assistant?.id || material?.assistant_id,
    ]
  );

export const knowledgeVisibility = material => {
  const ids = knowledgeAssistantIds(material);
  // A generated answer can have general visibility while inheriting its
  // document's effective agent list. The restriction flag alone is not an ACL.
  if (
    material?.documentable?.type === 'Captain::Document' &&
    material?.restricted_to_assistants === false &&
    ids.length
  ) {
    return 'personal';
  }
  if (material?.visibility) return material.visibility;

  return ids.length || material?.restricted_to_assistants === true
    ? 'personal'
    : 'general';
};

export const knowledgeAccessSignature = (visibility, ids) =>
  visibility === 'personal'
    ? `personal:${normalizeAssistantIds(ids)
        .sort((a, b) => a - b)
        .join(',')}`
    : 'general';

export const knowledgeAccessPayload = (visibility, ids) => ({
  visibility,
  assistant_id: null,
  allowed_assistant_ids:
    visibility === 'personal' ? normalizeAssistantIds(ids) : [],
});
