export const AGENT_TOOL_SCOPE = 'agent';
export const ASSISTANT_TOOL_SCOPE = 'assistant';
export const FAQ_LOOKUP_TOOL_ID = 'faq_lookup';
export const HANDOFF_TOOL_ID = 'handoff';
export const ADD_CONTACT_NOTE_TOOL_ID = 'add_contact_note';
export const ADD_PRIVATE_NOTE_TOOL_ID = 'add_private_note';

const CAPABILITY_TOOL_IDS_BY_SCOPE = Object.freeze({
  [AGENT_TOOL_SCOPE]: Object.freeze([
    FAQ_LOOKUP_TOOL_ID,
    HANDOFF_TOOL_ID,
    ADD_CONTACT_NOTE_TOOL_ID,
    ADD_PRIVATE_NOTE_TOOL_ID,
  ]),
  [ASSISTANT_TOOL_SCOPE]: Object.freeze([
    ADD_CONTACT_NOTE_TOOL_ID,
    ADD_PRIVATE_NOTE_TOOL_ID,
  ]),
});

const DEFAULT_CAPABILITY_TOOL_IDS_BY_SCOPE = Object.freeze({
  [AGENT_TOOL_SCOPE]: Object.freeze([FAQ_LOOKUP_TOOL_ID, HANDOFF_TOOL_ID]),
  [ASSISTANT_TOOL_SCOPE]: Object.freeze([]),
});

const activeScopeForUsageMode = usageMode =>
  usageMode === 'internal_assistant' ? ASSISTANT_TOOL_SCOPE : AGENT_TOOL_SCOPE;

const cloneAccess = access => JSON.parse(JSON.stringify(access || {}));
const hasOwn = (object, key) =>
  Object.prototype.hasOwnProperty.call(object, key);
const toStringArray = value => {
  if (Array.isArray(value)) {
    return value.map(String);
  }

  if (value === undefined || value === null) {
    return [];
  }

  return [String(value)];
};

const normalizeScopeAccess = scopeAccess => {
  if (
    !scopeAccess ||
    typeof scopeAccess !== 'object' ||
    Array.isArray(scopeAccess)
  ) {
    return null;
  }

  const toolIds = Array.from(new Set(toStringArray(scopeAccess.tool_ids)));

  return {
    ...scopeAccess,
    enabled: hasOwn(scopeAccess, 'enabled')
      ? scopeAccess.enabled !== false
      : true,
    tool_ids: toolIds,
  };
};

const isCapabilityTool = (scopeName, toolId) =>
  (CAPABILITY_TOOL_IDS_BY_SCOPE[scopeName] || []).includes(toolId);

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

export const normalizeCapabilityToolAccess = (toolAccess = {}) => {
  return Object.entries(cloneAccess(toolAccess)).reduce(
    (normalizedAccess, [scopeName, scopeAccess]) => {
      const normalizedScope = normalizeScopeAccess(scopeAccess);
      if (normalizedScope) {
        normalizedAccess[scopeName] = normalizedScope;
      }

      return normalizedAccess;
    },
    {}
  );
};

export const resolveToolAccessForUsageMode = (
  toolAccess = {},
  usageMode = 'external_agent'
) => {
  const normalizedAccess = normalizeCapabilityToolAccess(toolAccess);
  const activeScope = activeScopeForUsageMode(usageMode);

  if (hasOwn(normalizedAccess, activeScope)) {
    return normalizedAccess;
  }

  return {
    ...normalizedAccess,
    ...buildDefaultToolAccessForUsageMode(usageMode),
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
  const normalizedAccess = resolveToolAccessForUsageMode(toolAccess, usageMode);
  if (!isCapabilityTool(scopeName, toolId)) {
    return normalizedAccess;
  }

  const nextAccess = cloneAccess(normalizedAccess);
  const scopeAccess = {
    ...(nextAccess[scopeName] || {}),
    enabled: true,
    tool_ids: toStringArray(nextAccess?.[scopeName]?.tool_ids),
  };
  const selectedToolIds = new Set(toStringArray(scopeAccess.tool_ids));

  if (enabled) {
    selectedToolIds.add(toolId);
  } else {
    selectedToolIds.delete(toolId);
  }

  nextAccess[scopeName] = {
    ...scopeAccess,
    enabled: true,
    tool_ids: Array.from(selectedToolIds),
  };

  return normalizeCapabilityToolAccess(nextAccess);
};
