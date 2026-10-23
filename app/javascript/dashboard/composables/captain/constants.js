export const CAPTAIN_ERROR_TYPES = Object.freeze({
  ABORTED: 'aborted',
  API_ERROR: 'api_error',
  HTTP_PREFIX: 'http_',
  ABORT_ERROR: 'AbortError',
  CANCELED_ERROR: 'CanceledError',
});

export const CAPTAIN_GENERATION_FAILURE_REASONS = Object.freeze({
  EMPTY_RESPONSE: 'empty_response',
  EXCEPTION: 'exception',
});

// Status of a background «Предложить ответ» run (SuggestionState.status).
export const REPLY_SUGGESTION_STATUS = Object.freeze({
  QUEUED: 'queued',
  RUNNING: 'running',
  DRAFT: 'draft',
  NO_REPLY: 'no_reply',
  HUMAN_NEEDED: 'human_needed',
  FAILED: 'failed',
  CANCELLED: 'cancelled',
});

// Local UI phase of the reply suggestion (not sent to the backend).
export const REPLY_SUGGESTION_PHASE = Object.freeze({
  IDLE: 'idle',
  REQUESTING: 'requesting',
  QUEUED: 'queued',
  GENERATING: 'generating',
  DRAFT: 'draft',
  NOTICE: 'notice',
});

// Kind of the notice card shown above the reply box. It never carries a draft.
export const REPLY_SUGGESTION_NOTICE_KIND = Object.freeze({
  NO_REPLY: 'no_reply',
  HUMAN_NEEDED: 'human_needed',
  FAILED: 'failed',
  UNAVAILABLE: 'unavailable',
});

// error_code values of the POST reply_suggestion rejections the UI treats specially.
export const REPLY_SUGGESTION_POST_ERRORS = Object.freeze({
  VOICE_CHANNEL_UNSUPPORTED: 'voice_channel_unsupported',
  BUSY: 'busy',
});
