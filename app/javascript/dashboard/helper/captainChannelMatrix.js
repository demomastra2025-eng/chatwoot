// Pure helpers for the «Каналы» page (the text channels where the AI replies
// by itself). Payload shape: GET /captain/channel_matrix. A channel names no
// agent: the AI picks one among the enabled agents for every message.

export const VOICE_CHANNEL_TYPE = 'Channel::Voice';

// Voice channels keep their own agent editor and never appear in the matrix.
export const isTextChannel = channelType => channelType !== VOICE_CHANNEL_TYPE;

const asArray = value => (Array.isArray(value) ? value : []);

const toId = value => {
  const id = Number(value);
  return Number.isInteger(id) && id > 0 ? id : null;
};

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
