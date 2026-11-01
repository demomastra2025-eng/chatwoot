// The business draft never copies retired per-agent settings. Prompt and
// capability changes require verified platform access at serialization.

export const AGENT_DESCRIPTION_MAX_LENGTH = 400;
export const AGENT_INSTRUCTION_MAX_LENGTH = 20000;

const DRAFT_FIELDS = Object.freeze([
  'name',
  'routingDescription',
  'instruction',
  'capabilities',
]);

const hasOwn = (object, key) =>
  Boolean(object) && Object.prototype.hasOwnProperty.call(object, key);

const toText = value => (typeof value === 'string' ? value : '');

const trimmed = value => toText(value).trim();

export const resolveModelIcon = (model = {}) => {
  const raw =
    typeof model === 'string'
      ? model
      : `${model?.provider || ''} ${model?.id || ''} ${model?.display_name || ''}`;
  if (/anthropic|claude/i.test(raw)) {
    return { icon: 'i-logos-claude-icon', iconClass: '' };
  }
  if (/openai|chatgpt|\bgpt\b|gpt-|\bo[134]\b/i.test(raw)) {
    return { icon: 'i-ri-openai-fill', iconClass: 'text-n-slate-12' };
  }
  return { icon: '', iconClass: '' };
};

export const resolveDefaultAgentEffort = metadata => {
  const efforts = Array.isArray(metadata?.reasoning_efforts)
    ? metadata.reasoning_efforts
    : [];
  if (!efforts.length) return '';
  if (efforts.includes('low')) return 'low';
  if (efforts.includes('none')) return 'none';
  return efforts[0] || '';
};

export const buildAgentDraft = (assistant = {}) => {
  return {
    name: toText(assistant?.name),
    routingDescription: toText(assistant?.routing_description),
    ...(hasOwn(assistant, 'description')
      ? { instruction: toText(assistant.description) }
      : {}),
    ...(assistant?.config?.capabilities?.version === 1
      ? {
          capabilities: JSON.parse(
            JSON.stringify(assistant.config.capabilities)
          ),
        }
      : {}),
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

// Returns { valid, errors } where every error is a code: 'required' | 'max'.
// `base` (the saved draft) sets the instruction limit; without it the limit
// is the usual one or the draft's own length, whichever is larger.
export const validateAgentDraft = (
  draft,
  base = null,
  { canEditPrompts = false } = {}
) => {
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
  if (canEditPrompts && hasOwn(draft, 'instruction')) {
    if (!instruction.trim()) errors.instruction = 'required';
    else if (instruction.length > agentInstructionMaxLength(base || draft))
      errors.instruction = 'max';
  }

  return { valid: Object.keys(errors).length === 0, errors };
};

export const buildAgentUpdatePayload = (
  base,
  draft,
  { canEditPrompts = false } = {}
) => {
  const payload = {};
  if (!base || !draft) return payload;

  if (trimmed(base.name) !== trimmed(draft.name)) {
    payload.name = trimmed(draft.name);
  }
  if (trimmed(base.routingDescription) !== trimmed(draft.routingDescription)) {
    payload.routing_description = trimmed(draft.routingDescription);
  }
  if (
    canEditPrompts &&
    hasOwn(draft, 'instruction') &&
    base.instruction !== draft.instruction
  ) {
    payload.description = toText(draft.instruction);
  }

  if (
    canEditPrompts &&
    base.capabilities?.version === 1 &&
    draft.capabilities?.version === 1 &&
    JSON.stringify(base.capabilities) !== JSON.stringify(draft.capabilities)
  ) {
    payload.config = {
      capabilities: JSON.parse(JSON.stringify(draft.capabilities)),
    };
  }

  return payload;
};

export const isAgentDraftDirty = (base, draft, options = {}) =>
  Boolean(
    base &&
      draft &&
      Object.keys(buildAgentUpdatePayload(base, draft, options)).length
  );

// Moves the draft onto a newer saved record without losing the user's edits:
// a field still equal to the previous base (untouched) takes the new value,
// an edited field keeps the user's value.
export const rebaseAgentDraft = (previousBase, nextBase, draft) => {
  if (!previousBase || !draft) return { ...nextBase };
  return DRAFT_FIELDS.reduce((result, field) => {
    if (!hasOwn(nextBase, field) && !hasOwn(draft, field)) return result;
    result[field] =
      JSON.stringify(draft[field]) === JSON.stringify(previousBase[field])
        ? nextBase[field]
        : draft[field];
    return result;
  }, {});
};
