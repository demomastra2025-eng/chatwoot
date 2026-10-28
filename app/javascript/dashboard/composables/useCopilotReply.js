import { ref, computed, getCurrentScope, onScopeDispose } from 'vue';
import { useCaptain } from 'dashboard/composables/useCaptain';
import { useI18n } from 'vue-i18n';
import { useAlert, useTrack } from 'dashboard/composables';
import { CAPTAIN_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';
import {
  CAPTAIN_ERROR_TYPES,
  CAPTAIN_GENERATION_FAILURE_REASONS,
  REPLY_SUGGESTION_STATUS,
  REPLY_SUGGESTION_PHASE,
  REPLY_SUGGESTION_NOTICE_KIND,
  REPLY_SUGGESTION_POST_ERRORS,
} from 'dashboard/composables/captain/constants';
import TasksAPI from 'dashboard/api/captain/tasks';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';

// Actions that map to REWRITE events (with operation attribute)
const REWRITE_ACTIONS = [
  'improve',
  'fix_spelling_grammar',
  'casual',
  'professional',
  'expand',
  'shorten',
  'rephrase',
  'make_friendly',
  'make_formal',
  'simplify',
];

const REPLY_SUGGESTION_ACTION = 'reply_suggestion';
// Until the server tells the budget of the run (60 s for one agent, 120 s
// when the router chooses among several agents and may call a council).
const DEFAULT_BUDGET_SECONDS = 120;
// A new suggestion right after «Отменить» waits this long at most for the
// cancel to reach the server, so that the cancelled run is not reused.
const CANCEL_WAIT_MS = 2000;
// No cable event for this long (or until the run deadline plus the grace
// period, whichever is later) means the socket probably dropped: ask the API.
const WATCHDOG_MIN_MS = 15000;
const WATCHDOG_GRACE_MS = 20000;
const TICK_INTERVAL_MS = 1000;
// A card the manager decided shows its result this long, then leaves the panel.
const DECIDED_ACTION_LINGER_MS = 1500;

const PHASE = REPLY_SUGGESTION_PHASE;
const STATUS = REPLY_SUGGESTION_STATUS;
const NOTICE_KIND = REPLY_SUGGESTION_NOTICE_KIND;

const IN_FLIGHT_PHASES = [PHASE.REQUESTING, PHASE.QUEUED, PHASE.GENERATING];
const WAITING_PHASES = [PHASE.QUEUED, PHASE.GENERATING];
const SETTLED_PHASES = [PHASE.DRAFT, PHASE.NOTICE];

// «Разрешено» / «Отклонено»: the manager's decision is made and recorded.
function isDecidedAction(item) {
  return item?.status === 'approved' || item?.status === 'rejected';
}

function recordCopilotFeedback(payload) {
  if (typeof TasksAPI?.feedback !== 'function') return;
  try {
    const promise = TasksAPI.feedback(payload);
    if (promise && typeof promise.catch === 'function') {
      promise.catch(() => {});
    }
  } catch {
    // Non-blocking feedback telemetry
  }
}

// The cards the panel shows: the ones it already had and the new ones of the
// run (a card keeps the operator's decision). removedIds are the cards the run
// withdrew (a corrected card replaced them): they leave the panel.
function normalizePendingActionList(
  rawList,
  currentList = [],
  removedIds = []
) {
  const removed = new Set(
    (Array.isArray(removedIds) ? removedIds : []).map(id => String(id))
  );
  const hasNew = Array.isArray(rawList) && rawList.length > 0;
  if (!hasNew && !removed.size) return currentList;
  const byId = new Map();
  currentList.forEach(item => {
    const id = item?.action_id || item?.actionId;
    if (id && !removed.has(String(id))) byId.set(String(id), item);
  });
  (hasNew ? rawList : []).forEach(item => {
    if (!item || typeof item !== 'object') return;
    const id = item.action_id || item.actionId;
    if (!id || removed.has(String(id))) return;
    const key = String(id);
    const existing = byId.get(key);
    if (
      existing &&
      (existing.status === 'approved' || existing.status === 'rejected')
    ) {
      return;
    }
    byId.set(key, { ...existing, ...item, action_id: key });
  });
  return Array.from(byId.values());
}

function toEpochMs(value) {
  if (!value) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function sameConversation(left, right) {
  if (left === null || left === undefined) return false;
  if (right === null || right === undefined) return false;
  return Number(left) === Number(right);
}

function normalizeAgentInfo(agent) {
  if (!agent || typeof agent !== 'object') return null;
  const name = String(agent.name || '').trim();
  if (!name) return null;
  return {
    id: agent.id ?? null,
    name,
    avatarUrl: agent.avatar_url || agent.avatarUrl || '',
  };
}

/**
 * Gets the event key suffix based on action type.
 * @param {string} action - The action type
 * @returns {string} The event key prefix (REWRITE, SUMMARIZE, or REPLY_SUGGESTION)
 */
function getEventPrefix(action) {
  if (action === 'summarize') return 'SUMMARIZE';
  if (action === REPLY_SUGGESTION_ACTION) return 'REPLY_SUGGESTION';
  return 'REWRITE';
}

/**
 * Builds the analytics payload based on action type.
 * @param {string} action - The action type
 * @param {number} conversationId - The conversation ID
 * @param {number} [followUpCount] - Optional follow-up count
 * @returns {Object} The payload object
 */
function buildPayload(action, conversationId, followUpCount = undefined) {
  const payload = { conversationId };

  // Add operation for rewrite actions
  if (REWRITE_ACTIONS.includes(action)) {
    payload.operation = action;
  }

  // Add followUpCount if provided
  if (followUpCount !== undefined) {
    payload.followUpCount = followUpCount;
  }

  return payload;
}

function trackGenerationFailure({
  action,
  conversationId,
  followUpCount = undefined,
  stage,
  reason,
}) {
  useTrack(CAPTAIN_EVENTS.GENERATION_FAILED, {
    ...buildPayload(action, conversationId, followUpCount),
    stage,
    reason,
  });
}

/**
 * Composable for managing Copilot reply generation state and actions.
 * Extracts copilot-related logic from ReplyBox for cleaner code organization.
 *
 * «Предложить ответ» (reply_suggestion) is a background run on the server:
 *   idle -> requesting -> queued -> generating -> draft | notice | idle
 * The result is delivered by cable events (progress, result), survives
 * navigation (restoreForConversation) and is bound to one conversation:
 * events and fetched states of any other conversation are dropped.
 * Rewrite, summarize and follow-up stay synchronous requests.
 *
 * @param {Object} [options]
 * @param {boolean} [options.syncSuggestions=false] - Restore the server-side
 *   suggestion on conversation open and adopt results started from another
 *   tab. Only the conversation ReplyBox sets it, other hosts of the composable
 *   (new conversation form) must not pick up suggestions of the open chat.
 * @returns {Object} Copilot reply state and methods
 */
export function useCopilotReply({ syncSuggestions = false } = {}) {
  const {
    processEvent,
    followUp,
    currentChat,
    conversationId: captainConversationId,
    captainTextImprovementEnabled,
    startReplySuggestion: requestReplySuggestion,
    getReplySuggestionStatus: requestReplySuggestionStatus,
    cancelReplySuggestion: requestCancelReplySuggestion,
  } = useCaptain();
  const { t } = useI18n();

  const showEditor = ref(false);
  const isGenerating = ref(false);
  const isContentReady = ref(false);
  const generatedContent = ref('');
  const followUpContext = ref(null);
  const captainTrace = ref(null);
  const suggestionMeta = ref(null);
  const pendingActionsByConversation = ref({});
  const actionLoadingById = ref({});
  const liveProgress = ref(null);
  // The draft so far, while the AI is still writing it (cable preview events).
  // It is only a look ahead: the result replaces it, and anything that ends or
  // resets the run clears it. Never kept, never inserted.
  const streamingText = ref('');
  const abortController = ref(null);
  const requestId = ref(null);
  const lastAcceptedMeta = ref(null);

  // Reply suggestion (background run) state
  const suggestionPhase = ref(PHASE.IDLE);
  const suggestionRequestId = ref(null);
  const suggestionNotice = ref(null);
  const suggestionStale = ref(false);
  const suggestionEngine = ref(null);
  const suggestionTiming = ref({
    startedAt: null,
    deadlineAt: null,
    budgetSeconds: DEFAULT_BUDGET_SECONDS,
  });
  const localStartedAt = ref(null);
  const nowMs = ref(Date.now());

  // Tracking state
  const currentAction = ref(null);
  const followUpCount = ref(0);
  const trackedConversationId = ref(null);

  // Runs the manager cancelled, dismissed, applied or replaced. Late events
  // for them are dropped, so a finished suggestion never comes back.
  const ignoredRequestIds = new Set();
  // The number of the last preview taken for the run: an older one that
  // arrives late is dropped.
  let lastPreviewSeq = 0;
  // Bumped whenever local state is cleared; async continuations compare it to
  // know that the conversation or the user's intent changed while they waited.
  let epoch = 0;
  let startToken = null;
  // The cancel request that is still on its way to the server.
  let pendingCancel = null;
  let tickTimer = null;
  let watchdogTimer = null;
  // Cards that were decided and wait to leave the panel: `conversation:action`.
  const actionCloseTimers = new Map();

  const conversationId = computed(
    () => captainConversationId?.value ?? currentChat.value?.id
  );

  const activeConversationKey = computed(() =>
    String(conversationId.value || trackedConversationId.value || 'default')
  );

  const pendingActions = computed({
    get: () =>
      pendingActionsByConversation.value[activeConversationKey.value] || [],
    set: value => {
      pendingActionsByConversation.value = {
        ...pendingActionsByConversation.value,
        [activeConversationKey.value]: Array.isArray(value) ? value : [],
      };
    },
  });

  const isActive = computed(() => showEditor.value || isGenerating.value);

  // The cards on the panel: a card the manager closed (or that left after its
  // result was shown) stays in the list, marked, so that a later merge or the
  // cards of the draft meta never bring it back.
  const visibleActions = computed(() =>
    pendingActions.value.filter(
      item => item && (item.action_id || item.actionId) && !item.dismissed
    )
  );
  // Cards that still wait for the manager: not decided yet (a failed one can
  // be tried again or denied).
  const openActions = computed(() =>
    visibleActions.value.filter(item => !isDecidedAction(item))
  );
  // The run found that no reply is needed and only prepared actions: the cards
  // take the place of the editor until each is decided or all are cancelled.
  // A staff reply is needed (human_needed) or the text was inserted already:
  // the manager still writes, so the editor stays.
  const isActionsOnly = computed(
    () =>
      !isActive.value &&
      suggestionPhase.value === PHASE.NOTICE &&
      suggestionNotice.value?.kind === NOTICE_KIND.NO_REPLY &&
      visibleActions.value.length > 0
  );
  const isButtonDisabled = computed(
    () => isGenerating.value || !isContentReady.value
  );
  const editorTransitionKey = computed(() =>
    isActive.value || isActionsOnly.value ? 'copilot' : 'rich'
  );

  const isSuggestionInFlight = computed(() =>
    IN_FLIGHT_PHASES.includes(suggestionPhase.value)
  );
  const isQueued = computed(() => suggestionPhase.value === PHASE.QUEUED);
  // «Отменить» works for a background run and for any synchronous request
  const canCancel = computed(
    () =>
      isSuggestionInFlight.value ||
      (isGenerating.value && Boolean(abortController.value))
  );
  const canAccept = computed(
    () =>
      showEditor.value && !isGenerating.value && Boolean(generatedContent.value)
  );
  const elapsedSeconds = computed(() => {
    if (suggestionPhase.value !== PHASE.GENERATING) return null;
    const startedAt = suggestionTiming.value.startedAt ?? localStartedAt.value;
    if (!startedAt) return null;
    return Math.max(0, Math.floor((nowMs.value - startedAt) / 1000));
  });

  const isFullyIdle = () =>
    suggestionPhase.value === PHASE.IDLE &&
    !isGenerating.value &&
    !showEditor.value;

  // ---------------------------------------------------------------------
  // Timers: elapsed counter and the "no events" watchdog
  // ---------------------------------------------------------------------
  function startTicker() {
    if (tickTimer) return;
    nowMs.value = Date.now();
    tickTimer = setInterval(() => {
      nowMs.value = Date.now();
    }, TICK_INTERVAL_MS);
  }

  function stopTicker() {
    if (!tickTimer) return;
    clearInterval(tickTimer);
    tickTimer = null;
  }

  function stopWatchdog() {
    if (!watchdogTimer) return;
    clearTimeout(watchdogTimer);
    watchdogTimer = null;
  }

  function stopTimers() {
    stopTicker();
    stopWatchdog();
  }

  function isWaiting() {
    return WAITING_PHASES.includes(suggestionPhase.value);
  }

  function pendingKeyFor(conversation) {
    return String(conversation || 'default');
  }

  function clearPendingFor(conversation) {
    pendingActionsByConversation.value = {
      ...pendingActionsByConversation.value,
      [pendingKeyFor(conversation)]: [],
    };
  }

  function mergePendingActions(rawList, removedIds = []) {
    const hasNew = Array.isArray(rawList) && rawList.length > 0;
    const hasRemoved = Array.isArray(removedIds) && removedIds.length > 0;
    if (!hasNew && !hasRemoved) return;
    pendingActions.value = normalizePendingActionList(
      rawList,
      pendingActions.value,
      removedIds
    );
  }

  // The ids of the cards a result withdrew (on top level, or in the meta).
  function supersededIdsOf(result) {
    return (
      result?.superseded_action_ids ||
      result?.suggestion_meta?.superseded_action_ids ||
      []
    );
  }

  async function runWatchdog() {
    watchdogTimer = null;
    const id = suggestionRequestId.value;
    if (!id || !isWaiting()) return;
    const myEpoch = epoch;
    const answer = await requestReplySuggestionStatus({
      conversationId: trackedConversationId.value,
      suggestionRequestId: id,
    });
    if (myEpoch !== epoch || suggestionRequestId.value !== id) return;

    if (answer?.suggestion) {
      // eslint-disable-next-line no-use-before-define
      applySuggestionState(answer.suggestion);
    } else if (answer?.notFound || !answer?.failed) {
      // The server does not know this run any more: do not wait forever.
      // eslint-disable-next-line no-use-before-define
      applyFailed({
        suggestion_request_id: id,
        result: { reason_code: 'interrupted' },
      });
    }
    if (isWaiting()) {
      // eslint-disable-next-line no-use-before-define
      armWatchdog();
    }
  }

  function armWatchdog() {
    stopWatchdog();
    if (!isWaiting()) return;
    const { deadlineAt } = suggestionTiming.value;
    const untilDeadline = deadlineAt
      ? deadlineAt + WATCHDOG_GRACE_MS - Date.now()
      : 0;
    watchdogTimer = setTimeout(
      runWatchdog,
      Math.max(WATCHDOG_MIN_MS, untilDeadline)
    );
  }

  function setPhase(next) {
    suggestionPhase.value = next;
    isGenerating.value = IN_FLIGHT_PHASES.includes(next);
    if (WAITING_PHASES.includes(next)) {
      startTicker();
      armWatchdog();
    } else {
      stopTimers();
    }
  }

  function clearStreamingText() {
    streamingText.value = '';
    lastPreviewSeq = 0;
  }

  function resetSuggestionState() {
    stopTimers();
    clearStreamingText();
    suggestionPhase.value = PHASE.IDLE;
    suggestionRequestId.value = null;
    suggestionNotice.value = null;
    suggestionStale.value = false;
    suggestionEngine.value = null;
    suggestionTiming.value = {
      startedAt: null,
      deadlineAt: null,
      budgetSeconds: DEFAULT_BUDGET_SECONDS,
    };
    localStartedAt.value = null;
  }

  function updateTiming(source) {
    const current = suggestionTiming.value;
    suggestionTiming.value = {
      startedAt: toEpochMs(source?.started_at) ?? current.startedAt,
      deadlineAt: toEpochMs(source?.deadline_at) ?? current.deadlineAt,
      budgetSeconds:
        Number(source?.budget_seconds) ||
        current.budgetSeconds ||
        DEFAULT_BUDGET_SECONDS,
    };
  }

  // ---------------------------------------------------------------------
  // Applying a server state (POST 202, cable progress/result, GET status)
  // ---------------------------------------------------------------------
  // The conversation a state must belong to: the tracked run's conversation,
  // or the open one when nothing is tracked yet.
  function ownerConversation() {
    const isTracking =
      Boolean(suggestionRequestId.value) ||
      suggestionPhase.value === PHASE.REQUESTING;
    return isTracking ? trackedConversationId.value : conversationId.value;
  }

  function adoptRequest(state) {
    // The owner is read first: once the id is set the run is "tracked" and the
    // owner would be the (still empty) tracked conversation.
    const owner = ownerConversation();
    if (suggestionRequestId.value !== state.suggestion_request_id) {
      clearStreamingText();
    }
    suggestionRequestId.value = state.suggestion_request_id;
    trackedConversationId.value = owner;
    currentAction.value = REPLY_SUGGESTION_ACTION;
    if (state.engine) suggestionEngine.value = state.engine;
    if (!localStartedAt.value) localStartedAt.value = Date.now();
  }

  function applyProgress(state) {
    const id = state.suggestion_request_id;
    const sameRun = suggestionRequestId.value === id;
    if (sameRun && SETTLED_PHASES.includes(suggestionPhase.value)) return;
    const isQueuedState = state.status === STATUS.QUEUED;
    if (
      sameRun &&
      isQueuedState &&
      suggestionPhase.value === PHASE.GENERATING
    ) {
      return;
    }
    adoptRequest(state);
    updateTiming(state);
    isContentReady.value = false;
    if (state.progress && typeof state.progress === 'object') {
      liveProgress.value = state.progress;
      mergePendingActions(
        state.progress.pending_actions,
        state.progress.superseded_action_ids
      );
    }
    setPhase(isQueuedState ? PHASE.QUEUED : PHASE.GENERATING);
  }

  function showNotice(notice, state) {
    suggestionNotice.value = {
      kind: notice.kind,
      reason: notice.reason ?? null,
      reasonCode: notice.reasonCode ?? null,
      reasonSource: notice.reasonSource ?? null,
      agent: notice.agent ?? null,
      canRetry: Boolean(notice.canRetry),
      stale: Boolean(state?.stale),
    };
    suggestionStale.value = Boolean(state?.stale);
    showEditor.value = false;
    generatedContent.value = '';
    followUpContext.value = null;
    captainTrace.value = null;
    suggestionMeta.value = null;
    liveProgress.value = null;
    clearStreamingText();
    setPhase(PHASE.NOTICE);
  }

  function applyFailed(state, restored = false) {
    const reasonCode = state.result?.reason_code ?? null;
    adoptRequest(state);
    clearPendingFor(trackedConversationId.value);
    showNotice({ kind: NOTICE_KIND.FAILED, reasonCode, canRetry: true }, state);
    if (!restored) {
      trackGenerationFailure({
        action: REPLY_SUGGESTION_ACTION,
        conversationId: trackedConversationId.value,
        stage: 'initial',
        reason: reasonCode || CAPTAIN_GENERATION_FAILURE_REASONS.EXCEPTION,
      });
    }
  }

  function applyDraft(state, restored) {
    const result = state.result || {};
    const message = typeof result.message === 'string' ? result.message : '';
    if (!message.trim()) {
      // A draft without text is a failure, never an empty editor.
      applyFailed(
        { ...state, result: { reason_code: 'empty_output' } },
        restored
      );
      return;
    }
    const cameFromGenerating = isGenerating.value;
    // The panel already shows the draft as it was written: the final text takes
    // its place in the same panel, with no transition to wait for.
    const wasWritten = Boolean(streamingText.value.trim());
    adoptRequest(state);
    clearStreamingText();
    generatedContent.value = message;
    followUpContext.value = result.follow_up_context ?? null;
    // The final trace only: the live progress trace is a partial view.
    captainTrace.value = result.captain_trace ?? null;
    suggestionMeta.value = result.suggestion_meta ?? null;
    mergePendingActions(
      result.pending_actions?.length
        ? result.pending_actions
        : result.suggestion_meta?.pending_actions,
      supersededIdsOf(result)
    );
    requestId.value = state.suggestion_request_id;
    liveProgress.value = null;
    suggestionNotice.value = null;
    suggestionStale.value = Boolean(state.stale);
    showEditor.value = true;
    // The editor transition marks content ready after a live run; a draft
    // that appears without a generating state has no transition to wait for.
    isContentReady.value = !cameFromGenerating || wasWritten;
    setPhase(PHASE.DRAFT);
    if (!restored) {
      useTrack(
        CAPTAIN_EVENTS[`${getEventPrefix(REPLY_SUGGESTION_ACTION)}_USED`],
        buildPayload(REPLY_SUGGESTION_ACTION, trackedConversationId.value)
      );
    }
  }

  function applyOutcomeNotice(state) {
    const result = state.result || {};
    adoptRequest(state);
    mergePendingActions(result.pending_actions, supersededIdsOf(result));
    showNotice(
      {
        kind:
          state.status === STATUS.NO_REPLY
            ? NOTICE_KIND.NO_REPLY
            : NOTICE_KIND.HUMAN_NEEDED,
        reason: typeof result.reason === 'string' ? result.reason.trim() : '',
        reasonSource: result.reason_source ?? null,
        agent: normalizeAgentInfo(result.agent),
        canRetry: false,
      },
      state
    );
  }

  function applyCancelled(id) {
    ignoredRequestIds.add(id);
    // eslint-disable-next-line no-use-before-define
    reset(false);
  }

  /**
   * Applies a SuggestionState to the UI.
   * @returns {boolean} Whether the state was used.
   */
  function applySuggestionState(state, { restored = false } = {}) {
    const id = state?.suggestion_request_id;
    if (!id || ignoredRequestIds.has(id)) return false;
    // Never show a state of another conversation.
    if (
      state.conversation_id !== null &&
      state.conversation_id !== undefined &&
      !sameConversation(state.conversation_id, ownerConversation())
    ) {
      return false;
    }
    // A settled suggestion is never replaced by a repeat of the same run
    // (event + fetch, or a late 202 after the result): it would drop edits.
    if (
      suggestionRequestId.value === id &&
      SETTLED_PHASES.includes(suggestionPhase.value)
    ) {
      return false;
    }

    switch (state.status) {
      case STATUS.QUEUED:
      case STATUS.RUNNING:
        applyProgress(state);
        return true;
      case STATUS.DRAFT:
        applyDraft(state, restored);
        return true;
      case STATUS.NO_REPLY:
      case STATUS.HUMAN_NEEDED:
        applyOutcomeNotice(state);
        return true;
      case STATUS.FAILED:
        applyFailed(state, restored);
        return true;
      case STATUS.CANCELLED:
        applyCancelled(id);
        return true;
      default:
        return false;
    }
  }

  function applyStartError({ errorCode, error, errorType }) {
    // A refused request (voice, quota, switched off...) is "unavailable" and a
    // retry cannot help. Busy and unknown transport errors can be retried.
    const isUnavailable =
      Boolean(errorCode) && errorCode !== REPLY_SUGGESTION_POST_ERRORS.BUSY;
    showNotice(
      {
        kind: isUnavailable ? NOTICE_KIND.UNAVAILABLE : NOTICE_KIND.FAILED,
        reason: error || null,
        reasonCode: errorCode || errorType || null,
        canRetry: !isUnavailable,
      },
      null
    );
    trackGenerationFailure({
      action: REPLY_SUGGESTION_ACTION,
      conversationId: trackedConversationId.value,
      stage: 'initial',
      reason:
        errorCode || errorType || CAPTAIN_GENERATION_FAILURE_REASONS.EXCEPTION,
    });
  }

  // ---------------------------------------------------------------------
  // Cable events
  // ---------------------------------------------------------------------
  function shouldAcceptEvent(data) {
    const id = data?.suggestion_request_id;
    if (!id || ignoredRequestIds.has(id)) return false;

    // (a) the run this composable follows
    if (suggestionRequestId.value) {
      return (
        id === suggestionRequestId.value &&
        (data.conversation_id === null ||
          data.conversation_id === undefined ||
          sameConversation(data.conversation_id, trackedConversationId.value))
      );
    }

    // (b) our own POST is in flight and the first event beat the 202, or the
    // run was started from another tab of this user in this conversation.
    const requesting = suggestionPhase.value === PHASE.REQUESTING;
    if (!requesting && !(syncSuggestions && isFullyIdle())) return false;
    return sameConversation(
      data.conversation_id,
      requesting ? trackedConversationId.value : conversationId.value
    );
  }

  function handleProgressEvent(data) {
    if (!shouldAcceptEvent(data)) return;
    const canFollow =
      isSuggestionInFlight.value || suggestionPhase.value === PHASE.IDLE;
    if (!canFollow) return;
    applySuggestionState({
      ...data,
      status: data.status === STATUS.QUEUED ? STATUS.QUEUED : STATUS.RUNNING,
      progress: data,
    });
  }

  // The AI is writing the draft: show what it has written so far. A preview
  // belongs to the run this composable follows (the progress events start
  // following a run, a preview never does) and only counts while the run is
  // generating. Each preview carries the whole text so far, so a missed one
  // costs nothing; the number puts a late one out of play.
  function handlePreviewEvent(data) {
    if (!data?.suggestion_request_id) return;
    if (data.suggestion_request_id !== suggestionRequestId.value) return;
    if (!shouldAcceptEvent(data)) return;
    if (suggestionPhase.value !== PHASE.GENERATING) return;
    if (!sameConversation(data.conversation_id, trackedConversationId.value))
      return;

    const seq = Number(data.seq);
    if (!Number.isSafeInteger(seq) || seq <= lastPreviewSeq) return;
    lastPreviewSeq = seq;
    streamingText.value = typeof data.text === 'string' ? data.text : '';
  }

  function handleResultEvent(state) {
    if (!shouldAcceptEvent(state)) return;
    applySuggestionState(state);
  }

  function handleReconnect() {
    if (suggestionRequestId.value && isWaiting()) {
      runWatchdog();
    }
  }

  function stopListening() {
    emitter.off(
      BUS_EVENTS.CAPTAIN_REPLY_SUGGESTION_PROGRESS,
      handleProgressEvent
    );
    emitter.off(
      BUS_EVENTS.CAPTAIN_REPLY_SUGGESTION_PREVIEW,
      handlePreviewEvent
    );
    emitter.off(BUS_EVENTS.CAPTAIN_REPLY_SUGGESTION_RESULT, handleResultEvent);
    emitter.off(BUS_EVENTS.WEBSOCKET_RECONNECT_COMPLETED, handleReconnect);
    stopTimers();
    // eslint-disable-next-line no-use-before-define
    clearActionCloseTimers();
  }

  // Listen from creation until the owner goes away: a result can arrive while
  // nothing is generating locally (second tab, returning to the chat).
  emitter.on(BUS_EVENTS.CAPTAIN_REPLY_SUGGESTION_PROGRESS, handleProgressEvent);
  emitter.on(BUS_EVENTS.CAPTAIN_REPLY_SUGGESTION_PREVIEW, handlePreviewEvent);
  emitter.on(BUS_EVENTS.CAPTAIN_REPLY_SUGGESTION_RESULT, handleResultEvent);
  emitter.on(BUS_EVENTS.WEBSOCKET_RECONNECT_COMPLETED, handleReconnect);
  if (getCurrentScope()) {
    onScopeDispose(stopListening);
  }

  // ---------------------------------------------------------------------
  // Reset / detach
  // ---------------------------------------------------------------------
  function clearLocalState() {
    epoch += 1;
    startToken = null;
    if (abortController.value) {
      abortController.value.abort();
      abortController.value = null;
    }
    showEditor.value = false;
    isGenerating.value = false;
    isContentReady.value = false;
    generatedContent.value = '';
    followUpContext.value = null;
    captainTrace.value = null;
    suggestionMeta.value = null;
    actionLoadingById.value = {};
    liveProgress.value = null;
    requestId.value = null;
    currentAction.value = null;
    followUpCount.value = 0;
    trackedConversationId.value = null;
    resetSuggestionState();
  }

  function trackDismissal() {
    if (!generatedContent.value || !currentAction.value) return;
    const eventKey = `${getEventPrefix(currentAction.value)}_DISMISSED`;
    useTrack(
      CAPTAIN_EVENTS[eventKey],
      buildPayload(
        currentAction.value,
        trackedConversationId.value,
        followUpCount.value
      )
    );
    recordCopilotFeedback({
      conversationId: trackedConversationId.value,
      requestId: requestId.value,
      suggestionRequestId: suggestionRequestId.value || undefined,
      copilotAction: currentAction.value,
      outcome: 'dismissed',
      followUpCount: followUpCount.value,
      generatedText: generatedContent.value,
    });
  }

  /**
   * Resets all copilot editor state and aborts any synchronous request.
   * A background reply suggestion is only forgotten locally here: use
   * cancelGeneration() to stop it on the server and dismiss() to reject it.
   * @param {boolean} [trackDismiss=true] - Whether to track dismiss event
   *   (rewrite and summarize only; a reply suggestion is dismissed by dismiss())
   */
  function reset(trackDismiss = true) {
    const isConversationSwitch =
      trackedConversationId.value &&
      conversationId.value &&
      Number(trackedConversationId.value) !== Number(conversationId.value);

    if (trackDismiss && currentAction.value !== REPLY_SUGGESTION_ACTION) {
      trackDismissal();
    }

    if (isConversationSwitch) {
      if (showEditor.value || isGenerating.value) {
        clearPendingFor(trackedConversationId.value);
      }
    } else {
      pendingActions.value = [];
    }
    clearLocalState();
  }

  /**
   * Forgets the local state when the open conversation changes. The server
   * run is NOT cancelled and no feedback is sent: the manager may return and
   * restoreForConversation() brings the result back.
   */
  function detach() {
    const tracked = trackedConversationId.value;
    const hadLiveState =
      showEditor.value ||
      isGenerating.value ||
      suggestionPhase.value !== PHASE.IDLE;
    if (tracked && hadLiveState) {
      clearPendingFor(tracked);
    }
    clearLocalState();
  }

  function pruneResolvedActions() {
    pendingActions.value = pendingActions.value.filter(
      item => item.status !== 'approved' && item.status !== 'rejected'
    );
  }

  /**
   * Toggles the copilot editor visibility.
   */
  function toggleEditor() {
    showEditor.value = !showEditor.value;
  }

  /**
   * Marks content as ready (called after transition completes).
   */
  function setContentReady() {
    isContentReady.value = true;
  }

  // ---------------------------------------------------------------------
  // Reply suggestion actions
  // ---------------------------------------------------------------------
  function sendCancel(id, conversation) {
    try {
      const promise = requestCancelReplySuggestion({
        conversationId: conversation,
        suggestionRequestId: id,
      });
      if (promise && typeof promise.then === 'function') {
        const settled = promise
          .catch(() => {})
          .finally(() => {
            if (pendingCancel === settled) pendingCancel = null;
          });
        pendingCancel = settled;
        return settled;
      }
    } catch {
      // The run ends on its own at the deadline
    }
    return Promise.resolve();
  }

  // A cancel that is still on its way: the server would otherwise hand the
  // run that is being cancelled back as the active one.
  function waitForPendingCancel() {
    if (!pendingCancel) return Promise.resolve();
    return Promise.race([
      pendingCancel,
      new Promise(resolve => {
        setTimeout(resolve, CANCEL_WAIT_MS);
      }),
    ]);
  }

  // The server handed back a run the manager cancelled (its cancel had not
  // arrived yet): cancel it again and ask once more.
  async function requestFreshSuggestion(targetConversation) {
    const answer = await requestReplySuggestion({
      conversationId: targetConversation,
    });
    const reusedId = answer?.state?.suggestion_request_id;
    if (!reusedId || !ignoredRequestIds.has(reusedId)) return answer;
    await sendCancel(reusedId, targetConversation);
    return requestReplySuggestion({ conversationId: targetConversation });
  }

  /**
   * Starts a background reply suggestion for the open conversation.
   * Does nothing while one is already running.
   */
  async function startReplySuggestion() {
    if (isSuggestionInFlight.value) return;
    const targetConversation = conversationId.value;
    if (!targetConversation) return;

    // Replaces a previous draft or notice
    reset(false);
    const token = { cancelled: false };
    startToken = token;
    const myEpoch = epoch;
    currentAction.value = REPLY_SUGGESTION_ACTION;
    followUpCount.value = 0;
    trackedConversationId.value = targetConversation;
    isContentReady.value = false;
    localStartedAt.value = Date.now();
    setPhase(PHASE.REQUESTING);

    if (pendingCancel) await waitForPendingCancel();
    const answer =
      myEpoch === epoch
        ? await requestFreshSuggestion(targetConversation)
        : null;

    if (myEpoch !== epoch) {
      // Cancelled, or the manager left the conversation while the request was
      // in flight. A cancel needs the id that only this answer carries.
      const lateId = answer?.state?.suggestion_request_id;
      if (token.cancelled && lateId) {
        ignoredRequestIds.add(lateId);
        sendCancel(lateId, targetConversation);
      }
      return;
    }

    if (!answer?.state) {
      applyStartError(answer || {});
      return;
    }
    applySuggestionState(answer.state);
    if (suggestionPhase.value === PHASE.REQUESTING) {
      // The state was refused (foreign conversation): do not hang
      applyStartError({});
    }
  }

  /**
   * Stops the current generation.
   * Reply suggestion: asks the server to cancel and closes the panel at once.
   * Synchronous request (rewrite, summarize, follow-up): aborts the HTTP call.
   */
  function cancelGeneration() {
    if (isSuggestionInFlight.value) {
      const id = suggestionRequestId.value;
      if (startToken) startToken.cancelled = true;
      if (id) {
        ignoredRequestIds.add(id);
        sendCancel(id, trackedConversationId.value);
      }
      reset(false);
      return;
    }
    if (!abortController.value) return;
    abortController.value.abort();
    abortController.value = null;
    if (generatedContent.value) {
      // A follow-up was cancelled: the previous draft stays
      isGenerating.value = false;
      return;
    }
    reset(false);
  }

  /**
   * «Отменить» of the panel. With a draft it drops the generated content, tells
   * the server and declines the cards that wait for a decision. When the run
   * left only cards (no text for the patient) it declines them and closes the
   * panel; the notice above the reply box stays, it has its own «Скрыть».
   */
  function dismiss() {
    if (isActionsOnly.value) {
      // eslint-disable-next-line no-use-before-define
      declineAndCloseActions();
      return;
    }
    // eslint-disable-next-line no-use-before-define
    declineOpenActions();
    const id = suggestionRequestId.value;
    trackDismissal();
    if (id) ignoredRequestIds.add(id);
    reset(false);
  }

  /**
   * Closes the notice card. The server marks the run consumed so the notice
   * does not come back when the manager returns to the conversation.
   */
  function dismissNotice({
    messageId = undefined,
    finalText = undefined,
  } = {}) {
    const id = suggestionRequestId.value;
    if (id) {
      ignoredRequestIds.add(id);
      recordCopilotFeedback({
        conversationId: trackedConversationId.value,
        requestId: id,
        suggestionRequestId: id,
        copilotAction: REPLY_SUGGESTION_ACTION,
        outcome: 'notice_dismissed',
        ...(messageId ? { messageId } : {}),
        ...(finalText ? { finalText } : {}),
      });
    }
    suggestionNotice.value = null;
    suggestionStale.value = false;
    currentAction.value = null;
    resetSuggestionState();
  }

  function retrySuggestion() {
    return startReplySuggestion();
  }

  /**
   * Brings back the suggestion of the open conversation after navigation:
   * a running one keeps its live progress, a finished one shows its draft or
   * notice. A result is applied only if it belongs to this conversation.
   */
  async function restoreForConversation() {
    if (!syncSuggestions) return;
    if (captainTextImprovementEnabled?.value === false) return;
    const targetConversation = conversationId.value;
    if (!targetConversation || !isFullyIdle()) return;

    const myEpoch = epoch;
    const answer = await requestReplySuggestionStatus({
      conversationId: targetConversation,
    });

    if (myEpoch !== epoch) return;
    if (!sameConversation(conversationId.value, targetConversation)) return;
    if (!isFullyIdle() || !answer?.suggestion) return;
    applySuggestionState(answer.suggestion, { restored: true });
  }

  // ---------------------------------------------------------------------
  // Synchronous actions (rewrite, summarize, follow-up)
  // ---------------------------------------------------------------------

  /**
   * Executes a copilot action (e.g., improve, fix grammar).
   * @param {string} action - The action type
   * @param {string} data - The content to process
   */
  async function execute(action, data) {
    if (action === REPLY_SUGGESTION_ACTION) {
      await startReplySuggestion();
      return;
    }
    // Another AI action replaces a running suggestion: stop it on the server
    if (isSuggestionInFlight.value) cancelGeneration();
    // Reset without tracking dismiss (starting new action)
    reset(false);
    const requestController = new AbortController();
    abortController.value = requestController;
    isGenerating.value = true;
    isContentReady.value = false;
    currentAction.value = action;
    followUpCount.value = 0;
    trackedConversationId.value = conversationId.value;

    try {
      const {
        message: content,
        followUpContext: newContext,
        captainTrace: trace,
        suggestionMeta: meta,
        pendingActions: incomingActions,
        requestId: newRequestId,
        errorType,
      } = await processEvent(action, data, {
        signal: requestController.signal,
      });

      if (requestController.signal.aborted) return;
      if (errorType === CAPTAIN_ERROR_TYPES.ABORTED) {
        if (abortController.value === requestController) {
          isGenerating.value = false;
        }
        return;
      }

      generatedContent.value = content;
      followUpContext.value = newContext;
      captainTrace.value = trace || null;
      suggestionMeta.value = meta || null;
      const candidateActions = incomingActions || meta?.pending_actions || [];
      pendingActions.value = normalizePendingActionList(
        candidateActions,
        pendingActions.value,
        meta?.superseded_action_ids
      );
      requestId.value = newRequestId || newContext?.request_id || null;
      if (content) {
        showEditor.value = true;
        // Track "Used" event on successful generation
        const eventKey = `${getEventPrefix(action)}_USED`;
        useTrack(
          CAPTAIN_EVENTS[eventKey],
          buildPayload(action, trackedConversationId.value)
        );
      } else if (errorType && errorType !== CAPTAIN_ERROR_TYPES.ABORTED) {
        trackGenerationFailure({
          action,
          conversationId: trackedConversationId.value,
          stage: 'initial',
          reason: errorType,
        });
      } else {
        trackGenerationFailure({
          action,
          conversationId: trackedConversationId.value,
          stage: 'initial',
          reason: CAPTAIN_GENERATION_FAILURE_REASONS.EMPTY_RESPONSE,
        });
      }
      isGenerating.value = false;
    } catch (error) {
      if (
        requestController.signal.aborted ||
        error?.name === CAPTAIN_ERROR_TYPES.ABORT_ERROR ||
        error?.name === CAPTAIN_ERROR_TYPES.CANCELED_ERROR
      ) {
        return;
      }
      trackGenerationFailure({
        action,
        conversationId: trackedConversationId.value,
        stage: 'initial',
        reason: error?.name || CAPTAIN_GENERATION_FAILURE_REASONS.EXCEPTION,
      });
      isGenerating.value = false;
    } finally {
      if (abortController.value === requestController) {
        abortController.value = null;
      }
    }
  }

  /**
   * Sends a follow-up message to refine the current generated content.
   * @param {string} message - The follow-up message from the user
   */
  async function sendFollowUp(message) {
    if (!followUpContext.value || !message.trim()) return;

    const requestController = new AbortController();
    abortController.value = requestController;
    isGenerating.value = true;
    isContentReady.value = false;

    // Track follow-up sent event
    useTrack(CAPTAIN_EVENTS.FOLLOW_UP_SENT, {
      conversationId: trackedConversationId.value,
    });
    followUpCount.value += 1;

    try {
      const {
        message: content,
        followUpContext: updatedContext,
        requestId: updatedRequestId,
        errorType,
      } = await followUp({
        followUpContext: followUpContext.value,
        message,
        signal: requestController.signal,
      });

      if (requestController.signal.aborted) return;
      if (errorType === CAPTAIN_ERROR_TYPES.ABORTED) {
        if (abortController.value === requestController) {
          isGenerating.value = false;
        }
        return;
      }

      if (content) {
        generatedContent.value = content;
        followUpContext.value = updatedContext;
        requestId.value =
          updatedRequestId || updatedContext?.request_id || requestId.value;
        showEditor.value = true;
      } else if (errorType && errorType !== CAPTAIN_ERROR_TYPES.ABORTED) {
        trackGenerationFailure({
          action: currentAction.value,
          conversationId: trackedConversationId.value,
          followUpCount: followUpCount.value,
          stage: 'follow_up',
          reason: errorType,
        });
      } else {
        trackGenerationFailure({
          action: currentAction.value,
          conversationId: trackedConversationId.value,
          followUpCount: followUpCount.value,
          stage: 'follow_up',
          reason: CAPTAIN_GENERATION_FAILURE_REASONS.EMPTY_RESPONSE,
        });
      }
      isGenerating.value = false;
    } catch (error) {
      if (
        requestController.signal.aborted ||
        error?.name === CAPTAIN_ERROR_TYPES.ABORT_ERROR ||
        error?.name === CAPTAIN_ERROR_TYPES.CANCELED_ERROR
      ) {
        return;
      }
      trackGenerationFailure({
        action: currentAction.value,
        conversationId: trackedConversationId.value,
        followUpCount: followUpCount.value,
        stage: 'follow_up',
        reason: error?.name || CAPTAIN_GENERATION_FAILURE_REASONS.EXCEPTION,
      });
      isGenerating.value = false;
    } finally {
      if (abortController.value === requestController) {
        abortController.value = null;
      }
    }
  }

  function updatePendingActionState(actionId, patch, targetConvKey = null) {
    const key = String(actionId);
    const convKey = targetConvKey || activeConversationKey.value;
    const list = pendingActionsByConversation.value[convKey] || [];
    pendingActionsByConversation.value = {
      ...pendingActionsByConversation.value,
      [convKey]: list.map(item => {
        const id = String(item.action_id || item.actionId || '');
        if (id !== key) return item;
        return { ...item, ...patch, action_id: key };
      }),
    };
  }

  // ---------------------------------------------------------------------
  // Cards leave the panel: after their result was shown, or when closed
  // ---------------------------------------------------------------------
  function actionCloseKey(actionId, convKey) {
    return `${convKey}:${actionId}`;
  }

  /**
   * Takes a card off the panel at once. It stays in the list, marked, so that a
   * later merge never brings it back.
   */
  function closeAction(actionItem, targetConvKey = null) {
    const actionId =
      typeof actionItem === 'string'
        ? actionItem
        : actionItem?.action_id || actionItem?.actionId;
    if (!actionId) return;
    const convKey = targetConvKey || activeConversationKey.value;
    const timerKey = actionCloseKey(actionId, convKey);
    clearTimeout(actionCloseTimers.get(timerKey));
    actionCloseTimers.delete(timerKey);
    updatePendingActionState(actionId, { dismissed: true }, convKey);
  }

  // A decided card shows its result for a moment, then leaves by itself.
  function scheduleActionClose(actionId, convKey) {
    const timerKey = actionCloseKey(actionId, convKey);
    clearTimeout(actionCloseTimers.get(timerKey));
    actionCloseTimers.set(
      timerKey,
      setTimeout(() => closeAction(actionId, convKey), DECIDED_ACTION_LINGER_MS)
    );
  }

  function clearActionCloseTimers() {
    actionCloseTimers.forEach(timer => clearTimeout(timer));
    actionCloseTimers.clear();
  }

  /**
   * Approves and executes a pending action proposed by the agent in reply_suggestion.
   * @param {Object|string} actionItem - The action object or action_id string
   */
  async function approveAction(actionItem) {
    const actionId =
      typeof actionItem === 'string'
        ? actionItem
        : actionItem?.action_id || actionItem?.actionId;
    if (!actionId || actionLoadingById.value[actionId]) return null;

    const convKey = activeConversationKey.value;
    const existing = pendingActions.value.find(
      item => String(item.action_id || item.actionId) === String(actionId)
    );
    const digest = actionItem?.digest || existing?.digest;
    const targetConvId =
      actionItem?.conversation_display_id ||
      existing?.conversation_display_id ||
      trackedConversationId.value ||
      conversationId.value;

    actionLoadingById.value = {
      ...actionLoadingById.value,
      [actionId]: 'approving',
    };

    try {
      const response = await TasksAPI.approveAction({
        actionId,
        conversationId: targetConvId,
        digest,
      });
      const updated = response?.data?.action || {
        ...existing,
        status: response?.data?.status || 'approved',
      };
      updatePendingActionState(actionId, updated, convKey);
      if (isDecidedAction(updated)) scheduleActionClose(actionId, convKey);
      return updated;
    } catch (error) {
      // What the server says is for the logs: the staff get one plain line
      const failedAction = error?.response?.data?.action || {
        status: 'failed',
      };
      updatePendingActionState(actionId, failedAction, convKey);
      useAlert(t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_FAILED'));
      return null;
    } finally {
      const next = { ...actionLoadingById.value };
      delete next[actionId];
      actionLoadingById.value = next;
    }
  }

  /**
   * Rejects a pending action proposed by the agent in reply_suggestion.
   * @param {Object|string} actionItem - The action object or action_id string
   */
  async function rejectAction(actionItem) {
    const actionId =
      typeof actionItem === 'string'
        ? actionItem
        : actionItem?.action_id || actionItem?.actionId;
    if (!actionId || actionLoadingById.value[actionId]) return null;

    const convKey = activeConversationKey.value;
    const existing = pendingActions.value.find(
      item => String(item.action_id || item.actionId) === String(actionId)
    );
    const targetConvId =
      actionItem?.conversation_display_id ||
      existing?.conversation_display_id ||
      trackedConversationId.value ||
      conversationId.value;

    actionLoadingById.value = {
      ...actionLoadingById.value,
      [actionId]: 'rejecting',
    };

    try {
      const response = await TasksAPI.rejectAction({
        actionId,
        conversationId: targetConvId,
      });
      const updated = response?.data?.action || {
        ...existing,
        status: response?.data?.status || 'rejected',
      };
      updatePendingActionState(actionId, updated, convKey);
      if (isDecidedAction(updated)) scheduleActionClose(actionId, convKey);
      return updated;
    } catch {
      useAlert(t('CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_REJECT_FAILED'));
      return null;
    } finally {
      const next = { ...actionLoadingById.value };
      delete next[actionId];
      actionLoadingById.value = next;
    }
  }

  /**
   * Declines the cards that wait for a decision, each through rejectAction. A
   * card the server is executing is left alone.
   * @returns {Promise<Array>} What rejectAction returned for each card
   */
  function declineOpenActions() {
    return Promise.all(
      openActions.value
        .filter(item => item.status !== 'executing')
        .map(item => rejectAction(item))
    );
  }

  /**
   * «Отменить» when the run left only cards: declines them and closes the
   * panel at once, also the cards that wait to leave after their result. A card
   * the server could not decline stays, with the alert.
   */
  async function declineAndCloseActions() {
    const convKey = activeConversationKey.value;
    await declineOpenActions();
    (pendingActionsByConversation.value[convKey] || [])
      .filter(item => !item.dismissed && isDecidedAction(item))
      .forEach(item => closeAction(item, convKey));
  }

  /**
   * Accepts the generated content and returns it.
   * Note: Formatting is automatically stripped by the Editor component's
   * createState function based on the channel's schema.
   * @returns {string} The content ready for the editor
   */
  function accept() {
    const content = generatedContent.value;
    const acceptedRunId = suggestionRequestId.value;
    lastAcceptedMeta.value = {
      requestId: requestId.value,
      suggestionRequestId: acceptedRunId,
      action: currentAction.value || REPLY_SUGGESTION_ACTION,
      followUpCount: followUpCount.value,
      conversationId: trackedConversationId.value,
    };

    // Track "Applied" event
    if (currentAction.value) {
      const eventKey = `${getEventPrefix(currentAction.value)}_APPLIED`;
      useTrack(
        CAPTAIN_EVENTS[eventKey],
        buildPayload(
          currentAction.value,
          trackedConversationId.value,
          followUpCount.value
        )
      );
      recordCopilotFeedback({
        conversationId: trackedConversationId.value,
        requestId: requestId.value,
        suggestionRequestId: acceptedRunId || undefined,
        copilotAction: currentAction.value,
        outcome: 'applied',
        followUpCount: followUpCount.value,
        generatedText: content,
      });
    }

    if (acceptedRunId) ignoredRequestIds.add(acceptedRunId);
    // Reset state without tracking dismiss
    showEditor.value = false;
    generatedContent.value = '';
    followUpContext.value = null;
    captainTrace.value = null;
    suggestionMeta.value = null;
    liveProgress.value = null;
    requestId.value = null;
    currentAction.value = null;
    followUpCount.value = 0;
    resetSuggestionState();

    return content;
  }

  return {
    showEditor,
    isGenerating,
    isContentReady,
    generatedContent,
    followUpContext,
    captainTrace,
    suggestionMeta,
    pendingActions,
    visibleActions,
    openActions,
    actionLoadingById,
    liveProgress,
    streamingText,
    requestId,
    lastAcceptedMeta,

    suggestionPhase,
    suggestionRequestId,
    suggestionNotice,
    suggestionStale,
    suggestionEngine,
    suggestionTiming,
    elapsedSeconds,

    isActive,
    isActionsOnly,
    isButtonDisabled,
    isQueued,
    canCancel,
    canAccept,
    editorTransitionKey,

    reset,
    detach,
    pruneResolvedActions,
    toggleEditor,
    setContentReady,
    execute,
    startReplySuggestion,
    cancelGeneration,
    dismiss,
    dismissNotice,
    retrySuggestion,
    restoreForConversation,
    sendFollowUp,
    approveAction,
    rejectAction,
    closeAction,
    accept,
  };
}
