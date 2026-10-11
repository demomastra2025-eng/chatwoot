import {
  MAX_REASON_LABEL_LENGTH,
  isBuiltInReason,
  isReasonLocked,
  isSystemReason,
  sortReasons,
} from 'dashboard/routes/dashboard/captain/assistants/outcomes/reasonOrder';

// Workspace AI settings (GET/PATCH captain/settings, package relsettings).
//
// The page edits a draft that uses the UI values on the left of the map below.
// Reads accept the contract spelling and the legacy per-agent spelling; writes
// always go through this ONE map, so switching a value to what the backend
// really accepts is a one-line change here.
export const AI_SETTINGS_API_VALUES = Object.freeze({
  direction: Object.freeze({ inbound: 'inbound', outbound: 'outbound' }),
  ruleAction: Object.freeze({ handoff: 'handoff', rewrite: 'rewrite_once' }),
  safetyAction: Object.freeze({ block: 'block', flag: 'flag', off: 'off' }),
  messageMode: Object.freeze({ fixed: 'fixed', generated: 'generated' }),
  // Key of the on/off flag of a handoff or completion reason.
  reasonEnabledKey: 'enabled',
});

// Legacy spellings tolerated on read (per-agent config before relsettings).
const READ_ALIASES = Object.freeze({
  direction: {
    inbound: 'inbound',
    input: 'inbound',
    outbound: 'outbound',
    output: 'outbound',
  },
  ruleAction: {
    handoff: 'handoff',
    // Service-level block rules have the same public effect as a handoff.
    block: 'handoff',
    rewrite: 'rewrite',
    rewrite_once: 'rewrite',
  },
  safetyAction: { block: 'block', flag: 'flag', off: 'off', disabled: 'off' },
  messageMode: { fixed: 'fixed', generated: 'generated' },
});

// Top-level sections the page edits and sends. `availability` is read-only.
export const AI_SETTINGS_SECTIONS = Object.freeze([
  'understanding',
  'handoff',
  'faq',
  'conversation',
  'safety',
]);

export const UNDERSTANDING_KEYS = Object.freeze([
  'voice_messages',
  'images',
  'documents',
  'web_search',
  'web_page_reading',
]);
export const WEB_UNDERSTANDING_KEYS = Object.freeze([
  'web_search',
  'web_page_reading',
]);

export const SAFETY_ACTIONS = Object.freeze(['block', 'flag', 'off']);
export const MESSAGE_MODES = Object.freeze(['fixed', 'generated']);
export const CUSTOM_RULE_DIRECTIONS = Object.freeze(['inbound', 'outbound']);

// Same limits as Captain::Safety::CustomRulesConfig.
export const CUSTOM_RULE_LIMITS = Object.freeze({
  maxRules: 20,
  name: 120,
  instruction: 2000,
  message: 2000,
});
export const CUSTOM_RULE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const RESERVED_RULE_ID = 'none';

// Rewriting is possible only for the agent's own replies.
export const ruleActionsFor = direction =>
  direction === 'outbound' ? ['handoff', 'rewrite'] : ['handoff'];

const asObject = value =>
  value && typeof value === 'object' && !Array.isArray(value) ? value : {};

const readValue = (kind, raw, fallback) => {
  if (raw === undefined || raw === null) return fallback;
  const key = String(raw).trim().toLowerCase();
  const alias = READ_ALIASES[kind]?.[key];
  if (alias) return alias;
  const apiValues = AI_SETTINGS_API_VALUES[kind] || {};
  const uiValue = Object.keys(apiValues).find(ui => apiValues[ui] === key);
  return uiValue || fallback;
};

const writeValue = (kind, uiValue) =>
  AI_SETTINGS_API_VALUES[kind]?.[uiValue] ?? uiValue;

const TRUE_VALUES = new Set(['true', 'enabled', 'on', '1']);
const FALSE_VALUES = new Set(['false', 'disabled', 'off', '0']);
const readBoolean = (raw, fallback) => {
  if (typeof raw === 'boolean') return raw;
  if (raw === 1) return true;
  if (raw === 0) return false;
  const key = typeof raw === 'string' ? raw.trim().toLowerCase() : '';
  if (TRUE_VALUES.has(key)) return true;
  if (FALSE_VALUES.has(key)) return false;
  return fallback;
};

const readSeconds = raw => {
  if (raw === null || raw === undefined || raw === '') return 0;
  const value = Number(raw);
  return Number.isFinite(value) && value >= 0 ? Math.round(value) : 0;
};

const readText = raw => {
  if (typeof raw === 'string') return raw;
  if (raw === null || raw === undefined) return '';
  return String(raw);
};

const readReasonEnabled = raw => {
  const value = [
    raw[AI_SETTINGS_API_VALUES.reasonEnabledKey],
    raw.enabled,
    raw.active,
  ].find(item => typeof item === 'boolean');
  return value === undefined ? true : value;
};

// {id, label, enabled, builtin}; `locked: true` is kept only when the API sends
// it (a reason the platform keeps on), and is never written back.
export const normalizeReason = raw => {
  if (!raw || typeof raw !== 'object') return null;
  if (raw.id === undefined || raw.id === null || raw.id === '') return null;
  const id = String(raw.id);
  const reason = {
    id,
    label: readText(raw.label),
    enabled: readReasonEnabled(raw),
    builtin:
      typeof raw.builtin === 'boolean' ? raw.builtin : isBuiltInReason({ id }),
  };
  if (raw.locked === true) reason.locked = true;
  if (isReasonLocked(reason)) reason.enabled = true;
  return reason;
};

// The backend falls back to the English "Other" label for the system reason;
// `otherLabel` (the localized name) replaces it, like the old per-agent form.
const BACKEND_OTHER_LABEL = 'other';

export const normalizeReasons = (raw, { otherLabel = '' } = {}) => {
  if (!Array.isArray(raw)) return [];
  const seen = new Set();
  const reasons = [];
  raw.forEach(item => {
    const reason = normalizeReason(item);
    if (!reason || seen.has(reason.id)) return;
    seen.add(reason.id);
    const label = reason.label.trim().toLowerCase();
    if (
      otherLabel &&
      isSystemReason(reason) &&
      (!label || label === BACKEND_OTHER_LABEL)
    ) {
      reason.label = otherLabel;
    }
    reasons.push(reason);
  });
  return sortReasons(reasons);
};

// Legacy per-agent messages were plain strings; an empty one meant "off".
export const normalizeStatusMessage = raw => {
  if (typeof raw === 'string') {
    return { enabled: raw.trim().length > 0, mode: 'fixed', text: raw };
  }
  const value = asObject(raw);
  return {
    enabled: readBoolean(value.enabled, false),
    mode: readValue('messageMode', value.mode, 'fixed'),
    text: readText(value.text),
  };
};

export const normalizeCustomRule = raw => {
  if (!raw || typeof raw !== 'object') return null;
  const direction = readValue('direction', raw.direction, 'inbound');
  const action = readValue('ruleAction', raw.action, 'handoff');
  return {
    id: readText(raw.id),
    name: readText(raw.name),
    direction,
    instruction: readText(raw.instruction),
    action: ruleActionsFor(direction).includes(action) ? action : 'handoff',
    enabled: readBoolean(raw.enabled, true),
    message: readText(raw.message),
  };
};

export const normalizeCustomRules = raw =>
  Array.isArray(raw) ? raw.map(normalizeCustomRule).filter(Boolean) : [];

// `options.otherLabel`: localized name of the system "Other" reason.
export const toAiSettingsDraft = (payload, options = {}) => {
  const data = asObject(payload);
  const understanding = asObject(data.understanding);
  const handoff = asObject(data.handoff);
  const faq = asObject(data.faq);
  const conversation = asObject(data.conversation);
  const safety = asObject(data.safety);
  const reasonOptions = { otherLabel: options.otherLabel || '' };

  return {
    understanding: {
      voice_messages: readBoolean(understanding.voice_messages, true),
      images: readBoolean(understanding.images, true),
      documents: readBoolean(understanding.documents, true),
      web_search: readBoolean(understanding.web_search, false),
      web_page_reading: readBoolean(understanding.web_page_reading, false),
    },
    handoff: {
      handoff_reasons: normalizeReasons(handoff.handoff_reasons, reasonOptions),
      completion_reasons: normalizeReasons(
        handoff.completion_reasons,
        reasonOptions
      ),
      handoff_message: normalizeStatusMessage(handoff.handoff_message),
      resolution_message: normalizeStatusMessage(handoff.resolution_message),
      auto_completion_enabled: readBoolean(
        handoff.auto_completion_enabled,
        true
      ),
      auto_reply_on_last_incoming: readBoolean(
        handoff.auto_reply_on_last_incoming,
        false
      ),
    },
    faq: {
      generate_from_resolved: readBoolean(faq.generate_from_resolved, false),
    },
    conversation: {
      message_collapse_window_seconds: readSeconds(
        conversation.message_collapse_window_seconds
      ),
    },
    safety: {
      moderation_enabled: readBoolean(safety.moderation_enabled, false),
      prompt_injection_action: readValue(
        'safetyAction',
        safety.prompt_injection_action,
        'block'
      ),
      sensitive_info_action: readValue(
        'safetyAction',
        safety.sensitive_info_action,
        'block'
      ),
      custom_rules: normalizeCustomRules(safety.custom_rules),
    },
  };
};

export const readAiSettingsAvailability = payload => {
  const availability = asObject(asObject(payload).availability);
  return {
    web_access_configured: availability.web_access_configured !== false,
  };
};

const serializeReason = reason => ({
  id: reason.id,
  label: readText(reason.label).trim(),
  [AI_SETTINGS_API_VALUES.reasonEnabledKey]:
    isReasonLocked(reason) || reason.enabled !== false,
  builtin: reason.builtin === true,
});

const serializeStatusMessage = message => ({
  enabled: message?.enabled === true,
  mode: writeValue('messageMode', message?.mode || 'fixed'),
  text: readText(message?.text),
});

const serializeCustomRule = rule => ({
  id: rule.id,
  name: rule.name,
  direction: writeValue('direction', rule.direction),
  instruction: rule.instruction,
  action: writeValue('ruleAction', rule.action),
  enabled: rule.enabled === true,
  message: readText(rule.message),
});

const SECTION_SERIALIZERS = {
  understanding: value =>
    Object.fromEntries(
      UNDERSTANDING_KEYS.map(key => [key, value[key] === true])
    ),
  handoff: value => ({
    handoff_reasons: (value.handoff_reasons || []).map(serializeReason),
    completion_reasons: (value.completion_reasons || []).map(serializeReason),
    handoff_message: serializeStatusMessage(value.handoff_message),
    resolution_message: serializeStatusMessage(value.resolution_message),
    auto_completion_enabled: value.auto_completion_enabled === true,
    auto_reply_on_last_incoming: value.auto_reply_on_last_incoming === true,
  }),
  faq: value => ({
    generate_from_resolved: value.generate_from_resolved === true,
  }),
  conversation: value => ({
    message_collapse_window_seconds: Number(
      value.message_collapse_window_seconds
    ),
  }),
  safety: value => ({
    moderation_enabled: value.moderation_enabled === true,
    prompt_injection_action: writeValue(
      'safetyAction',
      value.prompt_injection_action
    ),
    sensitive_info_action: writeValue(
      'safetyAction',
      value.sensitive_info_action
    ),
    custom_rules: (value.custom_rules || []).map(serializeCustomRule),
  }),
};

export const serializeAiSettingsSection = (section, value) =>
  SECTION_SERIALIZERS[section](asObject(value));

// Only the sections that differ from the loaded draft, each sent whole in the
// contract shape. `availability` is never sent.
export const buildAiSettingsPatch = (baseDraft, draft) => {
  const patch = {};
  AI_SETTINGS_SECTIONS.forEach(section => {
    if (!draft?.[section]) return;
    const next = serializeAiSettingsSection(section, draft[section]);
    const base = baseDraft?.[section]
      ? serializeAiSettingsSection(section, baseDraft[section])
      : null;
    if (JSON.stringify(next) !== JSON.stringify(base)) patch[section] = next;
  });
  return patch;
};

export const isAiSettingsDirty = (baseDraft, draft) =>
  Object.keys(buildAiSettingsPatch(baseDraft, draft)).length > 0;

const validText = (value, limit, required = true) =>
  (value === undefined && !required) ||
  (typeof value === 'string' &&
    (!required || value.trim().length > 0) &&
    value.length <= limit);

const validRuleMetadata = rule =>
  typeof rule?.id === 'string' &&
  CUSTOM_RULE_ID_PATTERN.test(rule.id) &&
  rule.id !== RESERVED_RULE_ID &&
  CUSTOM_RULE_DIRECTIONS.includes(rule.direction) &&
  ruleActionsFor(rule.direction).includes(rule.action) &&
  typeof rule.enabled === 'boolean';

// { valid, tooMany, invalidRuleIds: [], fields: { [ruleId]: { name, ... } } }
export const validateCustomRules = rules => {
  const list = Array.isArray(rules) ? rules : [];
  const ids = list.map(rule => rule?.id);
  const duplicates = new Set(
    ids.filter((id, index) => ids.indexOf(id) !== index)
  );
  const result = {
    tooMany: list.length > CUSTOM_RULE_LIMITS.maxRules,
    invalidRuleIds: [],
    fields: {},
  };
  list.forEach(rule => {
    const fieldErrors = {};
    if (!validText(rule?.name, CUSTOM_RULE_LIMITS.name)) {
      fieldErrors.name = true;
    }
    if (!validText(rule?.instruction, CUSTOM_RULE_LIMITS.instruction)) {
      fieldErrors.instruction = true;
    }
    if (!validText(rule?.message, CUSTOM_RULE_LIMITS.message, false)) {
      fieldErrors.message = true;
    }
    if (Object.keys(fieldErrors).length) result.fields[rule?.id] = fieldErrors;
    if (!validRuleMetadata(rule) || duplicates.has(rule?.id)) {
      result.invalidRuleIds.push(rule?.id);
    }
  });
  result.valid =
    !result.tooMany &&
    !result.invalidRuleIds.length &&
    !Object.keys(result.fields).length;
  return result;
};

const reasonsValid = reasons =>
  (Array.isArray(reasons) ? reasons : []).every(reason => {
    const label = readText(reason?.label).trim();
    return label.length > 0 && label.length <= MAX_REASON_LABEL_LENGTH;
  });

export const statusMessageNeedsText = message =>
  message?.enabled === true &&
  message?.mode === 'fixed' &&
  !readText(message?.text).trim();

export const validCollapseWindow = value =>
  value !== '' &&
  value !== null &&
  value !== undefined &&
  Number.isInteger(Number(value)) &&
  Number(value) >= 0;

// { valid, errors: { handoff_reasons, completion_reasons, handoff_message,
//   resolution_message, collapse_window }, rules: validateCustomRules(...) }
export const validateAiSettingsDraft = draft => {
  const handoff = asObject(draft?.handoff);
  const errors = {};
  if (!reasonsValid(handoff.handoff_reasons)) errors.handoff_reasons = true;
  if (!reasonsValid(handoff.completion_reasons)) {
    errors.completion_reasons = true;
  }
  if (statusMessageNeedsText(handoff.handoff_message)) {
    errors.handoff_message = true;
  }
  if (statusMessageNeedsText(handoff.resolution_message)) {
    errors.resolution_message = true;
  }
  if (
    !validCollapseWindow(draft?.conversation?.message_collapse_window_seconds)
  ) {
    errors.collapse_window = true;
  }
  const rules = validateCustomRules(draft?.safety?.custom_rules);
  return {
    valid: !Object.keys(errors).length && rules.valid,
    errors,
    rules,
  };
};

// Server field paths (`safety.custom_rules[2].name`, `handoff.handoff_message`,
// `conversation.message_collapse_window_seconds`, ...) to page keys.
const FIELD_KEYS = [
  'handoff_reasons',
  'completion_reasons',
  'handoff_message',
  'resolution_message',
  'auto_completion_enabled',
  'auto_reply_on_last_incoming',
  'generate_from_resolved',
  'moderation_enabled',
  'prompt_injection_action',
  'sensitive_info_action',
  ...UNDERSTANDING_KEYS,
];
const RULE_PATH = /custom_rules\.(\d+)(?:\.([a-z_]+))?/;

const fieldTarget = (field, draft) => {
  const path = String(field || '')
    .replace(/\[(\d+)\]/g, '.$1')
    .toLowerCase();
  if (!path) return null;
  const ruleMatch = path.match(RULE_PATH);
  if (ruleMatch) {
    const rule = draft?.safety?.custom_rules?.[Number(ruleMatch[1])];
    if (!rule) return { key: 'custom_rules' };
    return { ruleId: rule.id, ruleField: ruleMatch[2] || 'rule' };
  }
  if (path.includes('custom_rules')) return { key: 'custom_rules' };
  if (path.includes('message_collapse_window_seconds')) {
    return { key: 'collapse_window' };
  }
  const key = FIELD_KEYS.find(item => path.includes(item));
  return key ? { key } : null;
};

// { fields: { key: message }, rules: { ruleId: { field: message } },
//   general: [message] } — what cannot be placed inline goes to `general`.
export const mapAiSettingsErrors = (errors, draft = null) => {
  const result = { fields: {}, rules: {}, general: [] };
  (Array.isArray(errors) ? errors : []).forEach(error => {
    const message = readText(error?.message || error?.code);
    const target = fieldTarget(error?.field, draft);
    if (!target) {
      if (message) result.general.push(message);
      return;
    }
    if (target.ruleId !== undefined) {
      const ruleErrors = result.rules[target.ruleId] || {};
      if (!ruleErrors[target.ruleField]) {
        ruleErrors[target.ruleField] = message;
      }
      result.rules[target.ruleId] = ruleErrors;
      return;
    }
    if (!result.fields[target.key]) result.fields[target.key] = message;
  });
  return result;
};
