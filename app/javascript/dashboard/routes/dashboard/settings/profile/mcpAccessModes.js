export const MCP_ACCESS_MODE_IDS = {
  BASIC: 'basic',
  FULL: 'full',
};

const LEGACY_MODE_IDS = {
  MEDIUM: 'medium',
};

const RISK_ORDER = {
  low: 0,
  medium: 1,
  high: 2,
  custom: 3,
};

const EMPTY_POLICY_FILTERS = {
  allowed_groups: [],
  blocked_groups: [],
  allowed_tool_ids: [],
  blocked_tool_ids: [],
  allowed_openapi_operation_ids: [],
  blocked_openapi_operation_ids: [],
};

export const MCP_ACCESS_MODE_POLICIES = {
  [MCP_ACCESS_MODE_IDS.BASIC]: {
    sources: {
      captain: true,
      openapi_read: true,
      openapi_write: false,
    },
    max_risk_level: 'medium',
    require_confirmation_for_mutations: true,
  },
  [MCP_ACCESS_MODE_IDS.FULL]: {
    sources: {
      captain: true,
      openapi_read: true,
      openapi_write: true,
    },
    max_risk_level: 'custom',
    require_confirmation_for_mutations: true,
  },
};

const normalizeModeId = modeId =>
  modeId === LEGACY_MODE_IDS.MEDIUM ? MCP_ACCESS_MODE_IDS.BASIC : modeId;

export const accessPolicyForMode = (modeId, { enabled = true } = {}) => {
  const normalizedModeId = normalizeModeId(modeId);
  const policy =
    MCP_ACCESS_MODE_POLICIES[normalizedModeId] ||
    MCP_ACCESS_MODE_POLICIES[MCP_ACCESS_MODE_IDS.BASIC];

  return {
    enabled,
    sources: { ...policy.sources },
    max_risk_level: policy.max_risk_level,
    require_confirmation_for_mutations:
      policy.require_confirmation_for_mutations,
    ...EMPTY_POLICY_FILTERS,
  };
};

export const modeFromAccessPolicy = access => {
  const sources = access?.sources || {};
  const fullRiskLevel = ['high', 'custom'].includes(access?.max_risk_level);
  const allCoreSourcesEnabled =
    sources.captain !== false &&
    sources.openapi_read !== false &&
    sources.openapi_write === true;

  return allCoreSourcesEnabled && fullRiskLevel
    ? MCP_ACCESS_MODE_IDS.FULL
    : MCP_ACCESS_MODE_IDS.BASIC;
};

export const allowsToolForAccessMode = (tool, modeId) => {
  const policy = accessPolicyForMode(modeId);
  const source = tool?.source;
  const riskLevel = tool?.risk_level || 'medium';

  if (source && policy.sources[source] === false) return false;

  const maxRiskValue = RISK_ORDER[policy.max_risk_level] ?? RISK_ORDER.medium;
  const toolRiskValue = RISK_ORDER[riskLevel] ?? RISK_ORDER.medium;

  return toolRiskValue <= maxRiskValue;
};
