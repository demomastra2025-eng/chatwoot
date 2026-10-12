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
  messageMode: Object.freeze({ fixed: 'fixed', generated: 'generated' }),
  // Key of the on/off flag of a handoff or completion reason.
  reasonEnabledKey: 'enabled',
});

// Legacy spellings tolerated on read (per-agent config before relsettings).
const READ_ALIASES = Object.freeze({
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

export const MESSAGE_MODES = Object.freeze(['fixed', 'generated']);
// Same limit as Captain::AccountSettings::MESSAGE_INSTRUCTION_MAX_LENGTH: the
// "how to write" guide of an AI-written handoff or closing message.
export const MESSAGE_INSTRUCTION_MAX_LENGTH = 500;

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
    return {
      enabled: raw.trim().length > 0,
      mode: 'fixed',
      text: raw,
      instruction: '',
    };
  }
  const value = asObject(raw);
  return {
    enabled: readBoolean(value.enabled, false),
    mode: readValue('messageMode', value.mode, 'fixed'),
    text: readText(value.text),
    instruction: readText(value.instruction),
  };
};

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
    // The client owns ONE safety switch. The other safety values (instruction
    // hijacking, keys and passwords, platform rules) are platform settings:
    // the page neither reads, validates nor sends them, so a save can never
    // reset or overwrite what is stored for them.
    safety: {
      moderation_enabled: readBoolean(safety.moderation_enabled, false),
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
  instruction: readText(message?.instruction),
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
  // The server merges a section key by key, so the one switch is all that is
  // sent; every other stored safety value stays as it is.
  safety: value => ({
    moderation_enabled: value.moderation_enabled === true,
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

const reasonsValid = reasons =>
  (Array.isArray(reasons) ? reasons : []).every(reason => {
    const label = readText(reason?.label).trim();
    return label.length > 0 && label.length <= MAX_REASON_LABEL_LENGTH;
  });

export const statusMessageNeedsText = message =>
  message?.enabled === true &&
  message?.mode === 'fixed' &&
  !readText(message?.text).trim();

// The "how to write" guide is optional and only matters for an AI-written message.
export const statusMessageInstructionTooLong = message =>
  readText(message?.instruction).length > MESSAGE_INSTRUCTION_MAX_LENGTH;

export const validCollapseWindow = value =>
  value !== '' &&
  value !== null &&
  value !== undefined &&
  Number.isInteger(Number(value)) &&
  Number(value) >= 0;

// { valid, errors: { handoff_reasons, completion_reasons, handoff_message,
//   resolution_message, handoff_message_instruction,
//   resolution_message_instruction, collapse_window } }
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
  if (statusMessageInstructionTooLong(handoff.handoff_message)) {
    errors.handoff_message_instruction = true;
  }
  if (statusMessageInstructionTooLong(handoff.resolution_message)) {
    errors.resolution_message_instruction = true;
  }
  if (
    !validCollapseWindow(draft?.conversation?.message_collapse_window_seconds)
  ) {
    errors.collapse_window = true;
  }
  return { valid: !Object.keys(errors).length, errors };
};

// Server field paths (`handoff.handoff_message`,
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
  ...UNDERSTANDING_KEYS,
];
// `handoff.handoff_message.instruction` belongs to the guide field, not the text.
const INSTRUCTION_ERROR_KEYS = [
  { message: 'handoff_message', key: 'handoff_message_instruction' },
  { message: 'resolution_message', key: 'resolution_message_instruction' },
];

const fieldTarget = field => {
  const path = String(field || '')
    .replace(/\[(\d+)\]/g, '.$1')
    .toLowerCase();
  if (!path) return null;
  if (path.includes('message_collapse_window_seconds')) {
    return { key: 'collapse_window' };
  }
  const instructionKey = INSTRUCTION_ERROR_KEYS.find(
    item => path.includes(item.message) && path.endsWith('.instruction')
  );
  if (instructionKey) return { key: instructionKey.key };
  const key = FIELD_KEYS.find(item => path.includes(item));
  return key ? { key } : null;
};

// { fields: { key: message }, general: [message] } — what cannot be placed
// inline goes to `general`.
export const mapAiSettingsErrors = errors => {
  const result = { fields: {}, general: [] };
  (Array.isArray(errors) ? errors : []).forEach(error => {
    const message = readText(error?.message || error?.code);
    const target = fieldTarget(error?.field);
    if (!target) {
      if (message) result.general.push(message);
      return;
    }
    if (!result.fields[target.key]) result.fields[target.key] = message;
  });
  return result;
};
