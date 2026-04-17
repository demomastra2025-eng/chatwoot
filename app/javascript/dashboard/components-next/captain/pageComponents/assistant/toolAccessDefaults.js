export const AGENT_TOOL_SCOPE = 'agent';
export const ASSISTANT_TOOL_SCOPE = 'assistant';
export const FAQ_LOOKUP_TOOL_ID = 'faq_lookup';
export const HANDOFF_TOOL_ID = 'handoff';
export const ADD_CONTACT_NOTE_TOOL_ID = 'add_contact_note';
export const ADD_PRIVATE_NOTE_TOOL_ID = 'add_private_note';

const AGENT_CAPABILITY_TOOL_IDS = Object.freeze([
  FAQ_LOOKUP_TOOL_ID,
  HANDOFF_TOOL_ID,
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
]);

const ASSISTANT_CAPABILITY_TOOL_IDS = Object.freeze([
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
]);

const DEFAULT_CAPABILITY_TOOL_IDS_BY_SCOPE = Object.freeze({
  [AGENT_TOOL_SCOPE]: Object.freeze([FAQ_LOOKUP_TOOL_ID, HANDOFF_TOOL_ID]),
  [ASSISTANT_TOOL_SCOPE]: Object.freeze([]),
});

const capabilityToolIdsForScope = scopeName => {
  if (scopeName === ASSISTANT_TOOL_SCOPE) {
    return ASSISTANT_CAPABILITY_TOOL_IDS;
  }

  return AGENT_CAPABILITY_TOOL_IDS;
};

const activeScopeForUsageMode = usageMode =>
  usageMode === 'internal_assistant' ? ASSISTANT_TOOL_SCOPE : AGENT_TOOL_SCOPE;

const cloneAccess = access => JSON.parse(JSON.stringify(access || {}));
const toStringArray = value => {
  if (Array.isArray(value)) {
    return value.map(String);
  }

  if (value === undefined || value === null) {
    return [];
  }

  return [String(value)];
};

export const buildDefaultToolAccess = () => ({});
export const buildDefaultToolAccessForUsageMode = (
  usageMode = 'external_agent'
) => {
  const activeScope = activeScopeForUsageMode(usageMode);
  const defaultToolIds =
    DEFAULT_CAPABILITY_TOOL_IDS_BY_SCOPE[activeScope] || [];

  if (!defaultToolIds.length) {
    return {};
  }

  return {
    [activeScope]: {
      enabled: true,
      tool_ids: [...defaultToolIds],
    },
  };
};

export const normalizeCapabilityToolAccess = (
  toolAccess = {},
  usageMode = 'external_agent'
) => {
  const activeScope = activeScopeForUsageMode(usageMode);
  const allowedToolIds = capabilityToolIdsForScope(activeScope);

  const scopeAccess = cloneAccess(toolAccess)?.[activeScope];
  if (!scopeAccess || typeof scopeAccess !== 'object') {
    return {};
  }

  const toolIds = Array.from(
    new Set(
      toStringArray(scopeAccess.tool_ids).filter(toolId =>
        allowedToolIds.includes(toolId)
      )
    )
  );

  if (!toolIds.length || scopeAccess.enabled === false) {
    return {};
  }

  return {
    [activeScope]: {
      enabled: true,
      tool_ids: toolIds,
    },
  };
};

export const isToolEnabled = (toolAccess, scopeName, toolId) => {
  const scopeAccess = toolAccess?.[scopeName];
  const selectedToolIds = toStringArray(scopeAccess?.tool_ids);

  return Boolean(scopeAccess?.enabled && selectedToolIds.includes(toolId));
};

export const setToolEnabled = (
  toolAccess,
  scopeName,
  toolId,
  enabled,
  usageMode = 'external_agent'
) => {
  const nextAccess = cloneAccess(toolAccess);
  const scopeAccess = {
    enabled: true,
    tool_ids: toStringArray(nextAccess?.[scopeName]?.tool_ids),
  };
  const selectedToolIds = new Set(toStringArray(scopeAccess.tool_ids));

  if (enabled) {
    scopeAccess.enabled = true;
    selectedToolIds.add(toolId);
  } else {
    selectedToolIds.delete(toolId);
  }

  scopeAccess.tool_ids = Array.from(selectedToolIds);
  if (scopeAccess.tool_ids.length) {
    nextAccess[scopeName] = scopeAccess;
  } else {
    delete nextAccess[scopeName];
  }

  return normalizeCapabilityToolAccess(nextAccess, usageMode);
};
