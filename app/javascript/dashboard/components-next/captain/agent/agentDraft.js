// Editable state of the agent page (header + «Инструкция» tab): name, short
// description, instruction and model settings. One draft, one «Сохранить».
// Only changed fields go to the server; model settings travel as one group in
// `config` because the server merges config keys (never resend the whole
// config).

export const AGENT_DESCRIPTION_MAX_LENGTH = 400;
export const AGENT_INSTRUCTION_MAX_LENGTH = 20000;

const DRAFT_FIELDS = Object.freeze([
  'name',
  'routingDescription',
  'instruction',
  'model',
  'thinkingEffort',
  'temperature',
  'handoffTeamId',
  'bookingResourceIds',
]);

const hasOwn = (object, key) =>
  Boolean(object) && Object.prototype.hasOwnProperty.call(object, key);

const toText = value => (typeof value === 'string' ? value : '');

const toTemperature = value => {
  if (value === null || value === undefined || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
};

const trimmed = value => toText(value).trim();

export const buildAgentDraft = (assistant = {}) => {
  const config = assistant?.config || {};
  return {
    name: toText(assistant?.name),
    routingDescription: toText(assistant?.routing_description),
    instruction: toText(assistant?.description),
    // '' = the platform default model chosen by the platform administrator.
    model: toText(config.model),
    thinkingEffort: toText(config.thinking_effort),
    temperature: toTemperature(config.temperature),
    handoffTeamId: config.handoff_team_id || '',
    bookingResourceIds: config.booking_scope?.resource_ids || [],
  };
};

// The saved instruction may be longer than the usual limit (legacy rules were
// merged into it), so it can always be edited without being cut.
export const agentInstructionMaxLength = base =>
  Math.max(AGENT_INSTRUCTION_MAX_LENGTH, toText(base?.instruction).length);

// Metadata of the model the agent answers with: the allowlisted catalog entry,
// or the server's `playground_model` for a saved model outside the list.
export const findAgentModelMetadata = ({
  models = [],
  modelId = '',
  assistant = null,
} = {}) => {
  if (!modelId) return {};
  const catalogModel = (Array.isArray(models) ? models : []).find(
    model => model?.id === modelId
  );
  if (catalogModel) return catalogModel;
  return assistant?.playground_model?.id === modelId
    ? assistant.playground_model
    : {};
};

// A parameter the model does not support is never sent (the server ignores
// it anyway), so it must not count as a change either. Unknown metadata
// (still loading, or no access to the catalog) keeps the raw value.
const effectiveTemperature = (temperature, metadata) => {
  if (!hasOwn(metadata, 'supports_temperature')) return temperature;
  return metadata.supports_temperature === true ? temperature : null;
};

const effectiveEffort = (effort, metadata) => {
  if (!Array.isArray(metadata?.reasoning_efforts)) return effort || '';
  return metadata.reasoning_efforts.includes(effort) ? effort : '';
};

const modelSettingsChanged = (base, draft, metadata) =>
  toText(base?.model) !== toText(draft?.model) ||
  effectiveEffort(base?.thinkingEffort, metadata) !==
    effectiveEffort(draft?.thinkingEffort, metadata) ||
  effectiveTemperature(base?.temperature ?? null, metadata) !==
    effectiveTemperature(draft?.temperature ?? null, metadata);

export const isAgentDraftDirty = (base, draft, modelMetadata = null) => {
  if (!base || !draft) return false;
  return (
    trimmed(base.name) !== trimmed(draft.name) ||
    trimmed(base.routingDescription) !== trimmed(draft.routingDescription) ||
    toText(base.instruction) !== toText(draft.instruction) ||
    String(base.handoffTeamId || '') !== String(draft.handoffTeamId || '') ||
    JSON.stringify(base.bookingResourceIds || []) !==
      JSON.stringify(draft.bookingResourceIds || []) ||
    modelSettingsChanged(base, draft, modelMetadata)
  );
};

// Returns { valid, errors } where every error is a code: 'required' | 'max'.
// `base` (the saved draft) sets the instruction limit; without it the limit
// is the usual one or the draft's own length, whichever is larger.
export const validateAgentDraft = (draft, base = null) => {
  const errors = {};
  if (!trimmed(draft?.name)) {
    errors.name = 'required';
  }

  const description = toText(draft?.routingDescription);
  if (!description.trim()) {
    errors.routingDescription = 'required';
  } else if (description.length > AGENT_DESCRIPTION_MAX_LENGTH) {
    errors.routingDescription = 'max';
  }

  const instruction = toText(draft?.instruction);
  if (!instruction.trim()) {
    errors.instruction = 'required';
  } else if (instruction.length > agentInstructionMaxLength(base || draft)) {
    errors.instruction = 'max';
  }

  return { valid: Object.keys(errors).length === 0, errors };
};

export const buildAgentUpdatePayload = (base, draft, modelMetadata = {}) => {
  const payload = {};
  if (!base || !draft) return payload;

  if (trimmed(base.name) !== trimmed(draft.name)) {
    payload.name = trimmed(draft.name);
  }
  if (trimmed(base.routingDescription) !== trimmed(draft.routingDescription)) {
    payload.routing_description = trimmed(draft.routingDescription);
  }
  if (toText(base.instruction) !== toText(draft.instruction)) {
    payload.description = toText(draft.instruction);
  }

  if (modelSettingsChanged(base, draft, modelMetadata)) {
    const efforts = Array.isArray(modelMetadata?.reasoning_efforts)
      ? modelMetadata.reasoning_efforts
      : [];
    payload.config = {
      model: toText(draft.model) || null,
      thinking_effort:
        draft.thinkingEffort && efforts.includes(draft.thinkingEffort)
          ? draft.thinkingEffort
          : null,
      temperature:
        modelMetadata?.supports_temperature === true
          ? toTemperature(draft.temperature)
          : null,
    };
  }

  if (String(base.handoffTeamId || '') !== String(draft.handoffTeamId || '')) {
    payload.config ||= {};
    payload.config.handoff_team_id = draft.handoffTeamId || null;
  }
  if (
    JSON.stringify(base.bookingResourceIds || []) !==
    JSON.stringify(draft.bookingResourceIds || [])
  ) {
    payload.config ||= {};
    payload.config.booking_scope = {
      resource_ids: (draft.bookingResourceIds || []).map(Number),
    };
  }

  return payload;
};

// Moves the draft onto a newer saved record without losing the user's edits:
// a field still equal to the previous base (untouched) takes the new value,
// an edited field keeps the user's value.
export const rebaseAgentDraft = (previousBase, nextBase, draft) => {
  if (!previousBase || !draft) return { ...nextBase };
  return DRAFT_FIELDS.reduce((result, field) => {
    result[field] =
      JSON.stringify(draft[field]) === JSON.stringify(previousBase[field])
        ? nextBase[field]
        : draft[field];
    return result;
  }, {});
};
