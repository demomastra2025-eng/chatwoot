// Pure helpers for the «Каналы» page (text channels × AI agents) and for the
// channel summaries on the agent gallery and the agent page. Payload shape:
// GET /captain/channel_matrix (package relchannels).

export const VOICE_CHANNEL_TYPE = 'Channel::Voice';

export const CHANNEL_SCOPES = Object.freeze({
  ALL: 'all',
  SELECTED: 'selected',
});

export const DEFAULT_AUTO_REPLY_MODE = 'always';

export const AUTO_REPLY_MODES = Object.freeze([
  'always',
  'working_hours',
  'outside_working_hours',
]);

// Voice channels keep their own agent editor and never appear in the matrix.
export const isTextChannel = channelType => channelType !== VOICE_CHANNEL_TYPE;

const asArray = value => (Array.isArray(value) ? value : []);

const toId = value => {
  const id = Number(value);
  return Number.isInteger(id) && id > 0 ? id : null;
};

export const toIdList = (ids = []) => [
  ...new Set(asArray(ids).map(toId).filter(Boolean)),
];

const sortIds = ids => [...ids].sort((left, right) => left - right);

const sameIdSet = (left = [], right = []) => {
  const leftIds = sortIds(toIdList(left));
  const rightIds = sortIds(toIdList(right));
  return (
    leftIds.length === rightIds.length &&
    leftIds.every((id, index) => id === rightIds[index])
  );
};

export const normalizeScope = scope =>
  scope === CHANNEL_SCOPES.SELECTED
    ? CHANNEL_SCOPES.SELECTED
    : CHANNEL_SCOPES.ALL;

const isAllScope = assistant => assistant.channel_scope === CHANNEL_SCOPES.ALL;

const normalizeAutoReplyMode = mode =>
  AUTO_REPLY_MODES.includes(mode) ? mode : DEFAULT_AUTO_REPLY_MODE;

const normalizeChannel = channel => ({
  inbox_id: toId(channel.inbox_id),
  name: channel.name || '',
  channel_type: channel.channel_type || '',
  ai_enabled: Boolean(channel.ai_enabled),
  main_assistant_id: toId(channel.main_assistant_id),
  assistant_ids: toIdList(channel.assistant_ids),
  auto_reply_mode: normalizeAutoReplyMode(channel.auto_reply_mode),
});

const normalizeAssistant = assistant => {
  const scope = normalizeScope(assistant.channel_scope);
  const isAll = scope === CHANNEL_SCOPES.ALL;
  return {
    id: toId(assistant.id),
    name: assistant.name || '',
    avatar_url: assistant.avatar_url || '',
    routing_description: assistant.routing_description || '',
    active: assistant.active !== false,
    channel_scope: scope,
    inbox_ids: isAll ? [] : toIdList(assistant.inbox_ids),
  };
};

// A normalized, editable copy of the GET payload. Works on a raw payload and
// on a draft produced by this function (idempotent).
export const toMatrixDraft = (matrix = null) => {
  const source = matrix || {};
  const channels = asArray(source.channels)
    .filter(channel => channel && isTextChannel(channel.channel_type))
    .map(normalizeChannel)
    .filter(channel => channel.inbox_id);
  const assistants = asArray(source.assistants)
    .filter(Boolean)
    .map(normalizeAssistant)
    .filter(assistant => assistant.id);

  return {
    default_main_assistant_id: toId(source.default_main_assistant_id),
    channels,
    assistants,
  };
};

const cloneDraft = draft => ({
  default_main_assistant_id: draft.default_main_assistant_id,
  channels: draft.channels.map(channel => ({
    ...channel,
    assistant_ids: [...channel.assistant_ids],
  })),
  assistants: draft.assistants.map(assistant => ({
    ...assistant,
    inbox_ids: [...assistant.inbox_ids],
  })),
});

const findAssistant = (draft, assistantId) =>
  draft.assistants.find(assistant => assistant.id === toId(assistantId)) ||
  null;

const findChannel = (draft, inboxId) =>
  draft.channels.find(channel => channel.inbox_id === toId(inboxId)) || null;

// Configured membership: «все каналы» or an explicit selection.
export const isDraftMember = (draft, assistantId, inboxId) => {
  const assistant = draft ? findAssistant(draft, assistantId) : null;
  const channelId = toId(inboxId);
  if (!assistant || !channelId) return false;

  return isAllScope(assistant) || assistant.inbox_ids.includes(channelId);
};

export const setDraftMembership = (draft, assistantId, inboxId, member) => {
  const next = cloneDraft(draft);
  const assistant = findAssistant(next, assistantId);
  const channelId = toId(inboxId);
  if (!assistant || !channelId) return next;

  if (member) {
    if (!isAllScope(assistant) && !assistant.inbox_ids.includes(channelId)) {
      assistant.inbox_ids.push(channelId);
    }
    return next;
  }

  if (isAllScope(assistant)) {
    // Leaving one channel turns «все каналы» into an explicit selection of
    // every current channel except this one.
    assistant.channel_scope = CHANNEL_SCOPES.SELECTED;
    assistant.inbox_ids = next.channels
      .map(channel => channel.inbox_id)
      .filter(id => id !== channelId);
  } else {
    assistant.inbox_ids = assistant.inbox_ids.filter(id => id !== channelId);
  }

  // The main agent must work in the channel: leaving it clears the star.
  const channel = findChannel(next, channelId);
  if (channel?.main_assistant_id === assistant.id) {
    channel.main_assistant_id = null;
  }
  return next;
};

export const setDraftScope = (draft, assistantId, scope) => {
  const next = cloneDraft(draft);
  const assistant = findAssistant(next, assistantId);
  if (!assistant) return next;

  if (normalizeScope(scope) === CHANNEL_SCOPES.ALL) {
    assistant.channel_scope = CHANNEL_SCOPES.ALL;
    assistant.inbox_ids = [];
    return next;
  }

  if (isAllScope(assistant)) {
    // «Только выбранные» keeps today's channels and stops adding new ones.
    assistant.channel_scope = CHANNEL_SCOPES.SELECTED;
    assistant.inbox_ids = next.channels.map(channel => channel.inbox_id);
  }
  return next;
};

export const setDraftMain = (draft, inboxId, assistantId) => {
  const next = cloneDraft(draft);
  const channel = findChannel(next, inboxId);
  if (!channel) return next;

  const mainId = toId(assistantId);
  if (!mainId) {
    channel.main_assistant_id = null;
    return next;
  }
  if (isDraftMember(next, mainId, channel.inbox_id)) {
    channel.main_assistant_id = mainId;
  }
  return next;
};

export const setDraftAiEnabled = (draft, inboxId, enabled) => {
  const next = cloneDraft(draft);
  const channel = findChannel(next, inboxId);
  if (!channel) return next;

  channel.ai_enabled = Boolean(enabled);
  if (!channel.ai_enabled || channel.main_assistant_id) return next;

  // Turning AI on without a main agent pre-selects the workspace default.
  const defaultMain = findAssistant(next, next.default_main_assistant_id);
  if (
    defaultMain?.active &&
    isDraftMember(next, defaultMain.id, channel.inbox_id)
  ) {
    channel.main_assistant_id = defaultMain.id;
  }
  return next;
};

export const setDraftAutoReplyMode = (draft, inboxId, mode) => {
  const next = cloneDraft(draft);
  const channel = findChannel(next, inboxId);
  if (channel) channel.auto_reply_mode = normalizeAutoReplyMode(mode);
  return next;
};

export const setDraftDefaultMain = (draft, assistantId) => {
  const next = cloneDraft(draft);
  next.default_main_assistant_id = toId(assistantId);
  return next;
};

// Non-blocking client hint: AI is on but nobody answers first. The server 422
// stays the source of truth.
export const channelsMissingMain = draft =>
  asArray(draft?.channels)
    .filter(channel => channel.ai_enabled && !channel.main_assistant_id)
    .map(channel => channel.inbox_id);

const channelChanged = (previous, channel) =>
  !previous ||
  previous.ai_enabled !== channel.ai_enabled ||
  previous.main_assistant_id !== channel.main_assistant_id ||
  previous.auto_reply_mode !== channel.auto_reply_mode;

const assistantChanged = (previous, assistant) =>
  !previous ||
  previous.channel_scope !== assistant.channel_scope ||
  !sameIdSet(previous.inbox_ids, assistant.inbox_ids);

// Minimal PATCH body: only changed keys; a changed channel row or agent is
// sent whole (with its own keys only).
export const buildChannelMatrixPatch = (base, draft) => {
  const baseDraft = toMatrixDraft(base);
  const nextDraft = toMatrixDraft(draft);
  const patch = {};

  if (
    baseDraft.default_main_assistant_id !== nextDraft.default_main_assistant_id
  ) {
    patch.default_main_assistant_id = nextDraft.default_main_assistant_id;
  }

  const baseChannels = new Map(
    baseDraft.channels.map(channel => [channel.inbox_id, channel])
  );
  const channels = nextDraft.channels
    .filter(channel =>
      channelChanged(baseChannels.get(channel.inbox_id), channel)
    )
    .map(channel => ({
      inbox_id: channel.inbox_id,
      ai_enabled: channel.ai_enabled,
      main_assistant_id: channel.main_assistant_id,
      auto_reply_mode: channel.auto_reply_mode,
    }));
  if (channels.length) patch.channels = channels;

  const baseAssistants = new Map(
    baseDraft.assistants.map(assistant => [assistant.id, assistant])
  );
  const assistants = nextDraft.assistants
    .filter(assistant =>
      assistantChanged(baseAssistants.get(assistant.id), assistant)
    )
    .map(assistant => ({
      id: assistant.id,
      channel_scope: assistant.channel_scope,
      inbox_ids: isAllScope(assistant) ? [] : sortIds(assistant.inbox_ids),
    }));
  if (assistants.length) patch.assistants = assistants;

  return patch;
};

export const isEmptyMatrixPatch = patch =>
  !patch || Object.keys(patch).length === 0;

const normalizeErrorItem = item => {
  if (typeof item === 'string') {
    return { inbox_id: null, assistant_id: null, code: '', message: item };
  }
  return {
    inbox_id: toId(item.inbox_id),
    assistant_id: toId(item.assistant_id),
    code: item.code || '',
    message: item.message || '',
  };
};

// 422 body: { errors: [{ inbox_id, assistant_id, code, message }] }. Anything
// else becomes one general error (its message may be empty: the page then
// shows its own generic text).
export const extractMatrixErrors = error => {
  const data = error?.response?.data || {};
  const errors = asArray(data.errors).filter(Boolean).map(normalizeErrorItem);
  if (errors.length) return errors;

  const status = error?.response?.status;
  const textErrors = typeof data.errors === 'string' ? data.errors : '';
  return [
    {
      inbox_id: null,
      assistant_id: null,
      code: data.code || (status ? `HTTP_${status}` : 'NETWORK_ERROR'),
      message: data.message || data.error || textErrors,
    },
  ];
};

// Groups errors for rendering: per channel row, and general ones (inbox_id
// null) for the banner above the matrix.
export const matrixErrorsByInbox = (errors = []) => {
  const byInbox = {};
  const general = [];
  const list = asArray(errors).filter(Boolean);

  list.forEach(error => {
    const inboxId = toId(error.inbox_id);
    const entry = {
      inboxId,
      assistantId: toId(error.assistant_id),
      code: error.code || '',
      message: error.message || '',
    };
    if (!inboxId) {
      general.push(entry);
      return;
    }
    if (!byInbox[inboxId]) byInbox[inboxId] = [];
    byInbox[inboxId].push(entry);
  });

  return { byInbox, general };
};

const summaryChannel = (channel, mainInboxIds) => ({
  inboxId: channel.inboxId,
  name: channel.name,
  channelType: channel.channelType,
  isMain: mainInboxIds.includes(channel.inboxId),
});

const summaryFromMatrix = (assistant, matrix) => {
  const assistantId = toId(assistant?.id);
  const matrixAssistant =
    asArray(matrix.assistants).find(item => toId(item?.id) === assistantId) ||
    null;
  const scope = normalizeScope(
    matrixAssistant?.channel_scope ?? assistant?.channel_scope
  );
  const explicitIds = toIdList(
    matrixAssistant?.inbox_ids ?? assistant?.inbox_ids
  );
  const channels = asArray(matrix.channels)
    .filter(channel => channel && isTextChannel(channel.channel_type))
    .map(channel => ({
      inboxId: toId(channel.inbox_id),
      name: channel.name || '',
      channelType: channel.channel_type || '',
      aiEnabled: Boolean(channel.ai_enabled),
      mainId: toId(channel.main_assistant_id),
      memberIds: toIdList(channel.assistant_ids),
    }))
    .filter(channel => channel.inboxId);

  const mainInboxIds = channels
    .filter(channel => channel.aiEnabled && channel.mainId === assistantId)
    .map(channel => channel.inboxId);
  const members = channels.filter(
    channel =>
      scope === CHANNEL_SCOPES.ALL ||
      explicitIds.includes(channel.inboxId) ||
      channel.memberIds.includes(assistantId) ||
      mainInboxIds.includes(channel.inboxId)
  );

  return {
    scope,
    memberInboxIds: members.map(channel => channel.inboxId),
    mainInboxIds,
    channels: members.map(channel => summaryChannel(channel, mainInboxIds)),
  };
};

const summaryFromAssistant = (assistant, inboxes) => {
  const scope = normalizeScope(assistant?.channel_scope);
  const inboxList = asArray(inboxes).filter(Boolean);
  const inboxById = new Map(inboxList.map(inbox => [toId(inbox.id), inbox]));
  const isKnownVoice = id =>
    inboxById.has(id) && !isTextChannel(inboxById.get(id).channel_type);
  const notVoice = id => !isKnownVoice(id);
  const textInboxes = inboxList
    .filter(inbox => isTextChannel(inbox.channel_type))
    .map(inbox => ({
      inboxId: toId(inbox.id),
      name: inbox.name || '',
      channelType: inbox.channel_type || '',
    }))
    .filter(inbox => inbox.inboxId);

  const mainInboxIds = toIdList(assistant?.main_in_inbox_ids).filter(notVoice);
  const baseIds =
    scope === CHANNEL_SCOPES.ALL
      ? textInboxes.map(inbox => inbox.inboxId)
      : toIdList(assistant?.inbox_ids);
  const memberIds = toIdList([...baseIds, ...mainInboxIds]).filter(notVoice);

  return {
    scope,
    memberInboxIds: memberIds,
    mainInboxIds,
    channels: textInboxes
      .filter(inbox => memberIds.includes(inbox.inboxId))
      .map(inbox => summaryChannel(inbox, mainInboxIds)),
  };
};

// Where an agent works. Uses the matrix when it is loaded (admins), otherwise
// the assistant JSON (channel_scope, inbox_ids, main_in_inbox_ids) plus the
// Vuex inboxes, voice channels excluded.
export const agentChannelSummary = ({
  assistant,
  matrix = null,
  inboxes = [],
} = {}) => {
  if (matrix && Array.isArray(matrix.channels)) {
    return summaryFromMatrix(assistant, matrix);
  }
  return summaryFromAssistant(assistant, inboxes);
};
