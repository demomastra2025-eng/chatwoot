import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { effectScope, ref } from 'vue';
import { useCopilotReply } from '../useCopilotReply';
import TasksAPI from 'dashboard/api/captain/tasks';
import { useAlert, useTrack } from 'dashboard/composables';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';

const mockProcessEvent = vi.fn();
const mockFollowUp = vi.fn();
const mockStartReplySuggestion = vi.fn();
const mockGetReplySuggestionStatus = vi.fn();
const mockCancelReplySuggestion = vi.fn();
const mockConversationId = ref(42);
const mockCurrentChat = ref({ id: 42 });
const mockTextImprovementEnabled = ref(true);

vi.mock('dashboard/composables/useCaptain', () => ({
  useCaptain: () => ({
    processEvent: mockProcessEvent,
    followUp: mockFollowUp,
    currentChat: mockCurrentChat,
    conversationId: mockConversationId,
    captainTextImprovementEnabled: mockTextImprovementEnabled,
    startReplySuggestion: mockStartReplySuggestion,
    getReplySuggestionStatus: mockGetReplySuggestionStatus,
    cancelReplySuggestion: mockCancelReplySuggestion,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));

// The composable is called outside a component here: the text of an alert is
// its key, which shows what the staff would be told
vi.mock('vue-i18n', async importOriginal => ({
  ...(await importOriginal()),
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/api/captain/tasks', () => ({
  default: {
    approveAction: vi.fn(),
    rejectAction: vi.fn(),
    feedback: vi.fn(() => Promise.resolve()),
  },
}));

// === Fixtures: SuggestionState exactly as in the API contract ===
const RUN = 'sr-1';

const suggestionState = (overrides = {}) => ({
  suggestion_request_id: RUN,
  status: 'queued',
  engine: 'agent',
  conversation_id: 42,
  conversation_record_id: 9042,
  created_at: '2026-10-24T09:12:03Z',
  started_at: null,
  finished_at: null,
  deadline_at: null,
  budget_seconds: 60,
  duration_ms: null,
  stale: false,
  progress: null,
  result: null,
  ...overrides,
});

const sampleAction = {
  action_id: 'act-55',
  tool_name: 'create_appointment',
  status: 'pending',
  title: 'Записать на приём',
  digest: 'dig-55',
};

const draftState = (resultOverrides = {}, overrides = {}) =>
  suggestionState({
    status: 'draft',
    finished_at: '2026-10-24T09:12:40Z',
    result: {
      message: 'Здравствуйте! Ближайшее окно к ЛОР-врачу завтра в 10:00.',
      agent: { id: 119, name: 'Сезім — запись', avatar_url: '' },
      captain_trace: { steps: ['final-trace'] },
      suggestion_meta: { agent: { id: 119, name: 'Сезім — запись' } },
      pending_actions: [],
      follow_up_context: { event_name: 'reply_suggestion' },
      ...resultOverrides,
    },
    ...overrides,
  });

const noticeState = (status, resultOverrides = {}, overrides = {}) =>
  suggestionState({
    status,
    finished_at: '2026-10-24T09:12:40Z',
    result: {
      reason: 'Пациент только поблагодарил, вопросов нет.',
      reason_source: 'agent',
      agent: { id: 84, name: 'Сезім', avatar_url: '' },
      pending_actions: [],
      ...resultOverrides,
    },
    ...overrides,
  });

const failedState = (reasonCode = 'timeout', overrides = {}) =>
  suggestionState({
    status: 'failed',
    result: { reason_code: reasonCode },
    ...overrides,
  });

const progressEvent = (overrides = {}) => ({
  suggestion_request_id: RUN,
  status: 'running',
  account_id: 78,
  conversation_id: 42,
  conversation_record_id: 9042,
  started_at: '2026-10-24T09:12:03Z',
  deadline_at: '2026-10-24T09:13:03Z',
  budget_seconds: 60,
  elapsed_ms: 4100,
  phase: 'thinking',
  active_agent: { id: 84, name: 'Сезім' },
  pending_actions: [],
  ...overrides,
});

const emitProgress = data =>
  emitter.emit(BUS_EVENTS.CAPTAIN_REPLY_SUGGESTION_PROGRESS, data);
const emitResult = data =>
  emitter.emit(BUS_EVENTS.CAPTAIN_REPLY_SUGGESTION_RESULT, data);

const switchConversation = id => {
  mockConversationId.value = id;
  mockCurrentChat.value = { id };
};

// Every composable lives in a scope that the test stops, so its bus listeners
// never leak into the next test.
const scopes = [];
const create = (options = { syncSuggestions: true }) => {
  const scope = effectScope();
  scopes.push(scope);
  return scope.run(() => useCopilotReply(options));
};

// Runs the full happy path up to a draft in conversation 42
const startAndReceiveDraft = async (copilot, resultOverrides = {}) => {
  mockStartReplySuggestion.mockResolvedValueOnce({
    state: suggestionState(),
  });
  await copilot.startReplySuggestion();
  emitResult(draftState(resultOverrides));
};

describe('useCopilotReply', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockConversationId.value = 42;
    mockCurrentChat.value = { id: 42 };
    mockTextImprovementEnabled.value = true;
    mockCancelReplySuggestion.mockResolvedValue({ ok: true });
    mockGetReplySuggestionStatus.mockResolvedValue({ suggestion: null });
  });

  afterEach(() => {
    scopes.splice(0).forEach(scope => scope.stop());
    vi.useRealTimers();
  });

  describe('reply suggestion state machine', () => {
    it('goes start -> queued -> generating -> draft and fills the editor from the result only', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });

      const started = copilot.startReplySuggestion();
      expect(copilot.suggestionPhase.value).toBe('requesting');
      expect(copilot.isGenerating.value).toBe(true);
      await started;

      expect(mockStartReplySuggestion).toHaveBeenCalledWith({
        conversationId: 42,
      });
      expect(copilot.suggestionPhase.value).toBe('queued');
      expect(copilot.isQueued.value).toBe(true);
      expect(copilot.suggestionRequestId.value).toBe(RUN);
      expect(copilot.suggestionEngine.value).toBe('agent');

      emitProgress(
        progressEvent({
          captain_trace: { steps: ['live-trace'] },
          pending_actions: [sampleAction],
        })
      );
      expect(copilot.suggestionPhase.value).toBe('generating');
      expect(copilot.isQueued.value).toBe(false);
      expect(copilot.liveProgress.value.phase).toBe('thinking');
      expect(copilot.pendingActions.value).toEqual([sampleAction]);
      expect(copilot.suggestionTiming.value).toEqual({
        startedAt: Date.parse('2026-10-24T09:12:03Z'),
        deadlineAt: Date.parse('2026-10-24T09:13:03Z'),
        budgetSeconds: 60,
      });

      emitResult(draftState());

      expect(copilot.suggestionPhase.value).toBe('draft');
      expect(copilot.isGenerating.value).toBe(false);
      expect(copilot.showEditor.value).toBe(true);
      expect(copilot.generatedContent.value).toBe(
        'Здравствуйте! Ближайшее окно к ЛОР-врачу завтра в 10:00.'
      );
      // The final trace of the result, never the partial live trace
      expect(copilot.captainTrace.value).toEqual({ steps: ['final-trace'] });
      expect(copilot.suggestionMeta.value).toEqual({
        agent: { id: 119, name: 'Сезім — запись' },
      });
      expect(copilot.followUpContext.value).toEqual({
        event_name: 'reply_suggestion',
      });
      expect(copilot.requestId.value).toBe(RUN);
      expect(copilot.liveProgress.value).toBeNull();
      expect(copilot.suggestionNotice.value).toBeNull();
      expect(useTrack).toHaveBeenCalledWith(
        expect.any(String),
        expect.objectContaining({ conversationId: 42 })
      );
    });

    it('does not take captainTrace from the live progress when the result has none', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();
      emitProgress(progressEvent({ captain_trace: { steps: ['live-trace'] } }));

      emitResult(draftState({ captain_trace: null }));

      expect(copilot.showEditor.value).toBe(true);
      expect(copilot.captainTrace.value).toBeNull();
    });

    it('ignores events of another run and follows the matching one', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();

      emitProgress(progressEvent({ suggestion_request_id: 'sr-other' }));
      expect(copilot.suggestionPhase.value).toBe('queued');
      expect(copilot.liveProgress.value).toBeNull();

      emitResult(draftState({}, { suggestion_request_id: 'sr-other' }));
      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.suggestionPhase.value).toBe('queued');

      emitProgress(progressEvent({ phase: 'tool_running' }));
      expect(copilot.liveProgress.value.phase).toBe('tool_running');
    });

    it('shows a no_reply result as a notice, never as editor content', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();

      emitResult(noticeState('no_reply', { pending_actions: [sampleAction] }));

      expect(copilot.suggestionPhase.value).toBe('notice');
      expect(copilot.suggestionNotice.value).toEqual({
        kind: 'no_reply',
        reason: 'Пациент только поблагодарил, вопросов нет.',
        reasonCode: null,
        reasonSource: 'agent',
        agent: { id: 84, name: 'Сезім', avatarUrl: '' },
        canRetry: false,
        stale: false,
      });
      expect(copilot.generatedContent.value).toBe('');
      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.isGenerating.value).toBe(false);
      expect(copilot.isActive.value).toBe(false);
      expect(copilot.canAccept.value).toBe(false);
      // Approval cards are separate from the text: they stay
      expect(copilot.pendingActions.value).toEqual([sampleAction]);
    });

    it('shows a human_needed result as a notice with the reason', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();

      emitResult(
        noticeState(
          'human_needed',
          { reason: 'В базе нет данных, кто оперирует ЛОР.' },
          { stale: true }
        )
      );

      expect(copilot.suggestionPhase.value).toBe('notice');
      expect(copilot.suggestionNotice.value).toMatchObject({
        kind: 'human_needed',
        reason: 'В базе нет данных, кто оперирует ЛОР.',
        canRetry: false,
        stale: true,
      });
      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.generatedContent.value).toBe('');
      expect(copilot.suggestionStale.value).toBe(true);
    });

    it('shows a failed result as a retryable status without any text and clears pending actions', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();
      emitProgress(progressEvent({ pending_actions: [sampleAction] }));
      expect(copilot.pendingActions.value).toHaveLength(1);

      emitResult(failedState('timeout'));

      expect(copilot.suggestionPhase.value).toBe('notice');
      expect(copilot.suggestionNotice.value).toMatchObject({
        kind: 'failed',
        reasonCode: 'timeout',
        reason: null,
        canRetry: true,
      });
      expect(copilot.generatedContent.value).toBe('');
      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.isGenerating.value).toBe(false);
      expect(copilot.pendingActions.value).toEqual([]);
      expect(useTrack).toHaveBeenCalledWith(
        expect.any(String),
        expect.objectContaining({ reason: 'timeout', stage: 'initial' })
      );
    });

    it('drops a card the run replaced with a corrected one, live and in the result', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();
      const corrected = { ...sampleAction, action_id: 'act-56' };
      const other = { ...sampleAction, action_id: 'act-57' };
      emitProgress(progressEvent({ pending_actions: [sampleAction, other] }));
      expect(copilot.pendingActions.value).toHaveLength(2);

      emitProgress(
        progressEvent({
          pending_actions: [other, corrected],
          superseded_action_ids: ['act-55'],
        })
      );
      expect(copilot.pendingActions.value.map(item => item.action_id)).toEqual([
        'act-57',
        'act-56',
      ]);

      emitProgress(progressEvent({ pending_actions: [sampleAction, other] }));
      emitResult(
        draftState({
          pending_actions: [other, corrected],
          superseded_action_ids: ['act-55'],
        })
      );
      expect(copilot.pendingActions.value.map(item => item.action_id)).toEqual([
        'act-57',
        'act-56',
      ]);
    });

    it('treats a draft without text as a failure instead of opening an empty editor', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();

      emitResult(draftState({ message: '   ' }));

      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.suggestionNotice.value).toMatchObject({
        kind: 'failed',
        reasonCode: 'empty_output',
      });
    });

    it('returns to idle on a cancelled result (cancelled from another tab)', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();
      emitProgress(progressEvent({ pending_actions: [sampleAction] }));

      emitResult(suggestionState({ status: 'cancelled' }));

      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(copilot.isGenerating.value).toBe(false);
      expect(copilot.suggestionRequestId.value).toBeNull();
      expect(copilot.pendingActions.value).toEqual([]);
      // and it does not come back
      emitProgress(progressEvent());
      expect(copilot.suggestionPhase.value).toBe('idle');
    });

    it('does not start a second run while one is in flight', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValue({ state: suggestionState() });
      await copilot.startReplySuggestion();

      await copilot.startReplySuggestion();
      await copilot.execute('reply_suggestion');

      expect(mockStartReplySuggestion).toHaveBeenCalledTimes(1);
    });

    it('execute("reply_suggestion") starts the background run', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ status: 'running' }),
      });

      await copilot.execute('reply_suggestion');

      expect(mockProcessEvent).not.toHaveBeenCalled();
      expect(copilot.suggestionPhase.value).toBe('generating');
    });

    it('adopts a result that beat the 202 and does not regress to queued afterwards', async () => {
      const copilot = create();
      let resolveStart;
      mockStartReplySuggestion.mockReturnValueOnce(
        new Promise(resolve => {
          resolveStart = resolve;
        })
      );

      const started = copilot.startReplySuggestion();
      emitResult(draftState());
      expect(copilot.suggestionPhase.value).toBe('draft');

      resolveStart({ state: suggestionState() });
      await started;

      expect(copilot.suggestionPhase.value).toBe('draft');
      expect(copilot.showEditor.value).toBe(true);
    });

    it('replaces a notice when the manager starts a new suggestion', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();
      emitResult(noticeState('no_reply'));
      expect(copilot.suggestionPhase.value).toBe('notice');

      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ suggestion_request_id: 'sr-2' }),
      });
      await copilot.startReplySuggestion();

      expect(copilot.suggestionNotice.value).toBeNull();
      expect(copilot.suggestionPhase.value).toBe('queued');
      expect(copilot.suggestionRequestId.value).toBe('sr-2');
    });
  });

  describe('start errors', () => {
    it('shows an unavailable notice for a voice conversation without an alert', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        errorCode: 'voice_channel_unsupported',
        error: 'В звонке нельзя отправить текст.',
        errorType: 'http_422',
      });

      await copilot.startReplySuggestion();

      expect(copilot.suggestionPhase.value).toBe('notice');
      expect(copilot.suggestionNotice.value).toMatchObject({
        kind: 'unavailable',
        reasonCode: 'voice_channel_unsupported',
        reason: 'В звонке нельзя отправить текст.',
        canRetry: false,
      });
      expect(copilot.isGenerating.value).toBe(false);
      expect(useAlert).not.toHaveBeenCalled();
    });

    it('offers a retry for busy and for unknown transport errors', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        errorCode: 'busy',
        error: 'Сейчас слишком много запросов к ИИ в аккаунте.',
        errorType: 'http_429',
      });
      await copilot.startReplySuggestion();
      expect(copilot.suggestionNotice.value).toMatchObject({
        kind: 'failed',
        reasonCode: 'busy',
        canRetry: true,
      });

      mockStartReplySuggestion.mockResolvedValueOnce({
        errorCode: null,
        error: null,
        errorType: 'api_error',
      });
      await copilot.retrySuggestion();
      expect(copilot.suggestionNotice.value).toMatchObject({
        kind: 'failed',
        reasonCode: 'api_error',
        reason: null,
        canRetry: true,
      });
      expect(useAlert).not.toHaveBeenCalled();
    });

    it('treats a refused request (quota, switched off) as unavailable', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        errorCode: 'quota_exceeded',
        error: 'Лимит ИИ-ответов исчерпан.',
        errorType: 'http_429',
      });

      await copilot.startReplySuggestion();

      expect(copilot.suggestionNotice.value).toMatchObject({
        kind: 'unavailable',
        reason: 'Лимит ИИ-ответов исчерпан.',
        canRetry: false,
      });
    });
  });

  describe('cancel', () => {
    it('cancels a running generation: calls the cancel API, closes the panel and ignores the late result', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();
      emitProgress(progressEvent({ pending_actions: [sampleAction] }));
      expect(copilot.canCancel.value).toBe(true);

      copilot.cancelGeneration();

      expect(mockCancelReplySuggestion).toHaveBeenCalledWith({
        conversationId: 42,
        suggestionRequestId: RUN,
      });
      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(copilot.isGenerating.value).toBe(false);
      expect(copilot.isActive.value).toBe(false);
      expect(copilot.pendingActions.value).toEqual([]);
      expect(copilot.canCancel.value).toBe(false);
      expect(TasksAPI.feedback).not.toHaveBeenCalled();

      // The run may still finish on the server before the cancel lands
      emitProgress(progressEvent());
      emitResult(draftState());
      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.generatedContent.value).toBe('');
    });

    it('starts a new run right after «Отменить» only once the cancel reached the server', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ status: 'running' }),
      });
      await copilot.startReplySuggestion();
      let resolveCancel;
      mockCancelReplySuggestion.mockReturnValueOnce(
        new Promise(resolve => {
          resolveCancel = resolve;
        })
      );
      copilot.cancelGeneration();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ suggestion_request_id: 'sr-2' }),
      });

      const restarted = copilot.startReplySuggestion();
      await Promise.resolve();
      expect(mockStartReplySuggestion).toHaveBeenCalledTimes(1);

      resolveCancel({ ok: true, status: 'cancelling' });
      await restarted;

      expect(mockStartReplySuggestion).toHaveBeenCalledTimes(2);
      expect(copilot.suggestionRequestId.value).toBe('sr-2');
      expect(copilot.suggestionPhase.value).toBe('queued');
      expect(copilot.suggestionNotice.value).toBeNull();
    });

    it('cancels again and asks once more when the server hands back the run it cancelled', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ status: 'running' }),
      });
      await copilot.startReplySuggestion();
      copilot.cancelGeneration();
      await Promise.resolve();
      mockStartReplySuggestion
        .mockResolvedValueOnce({
          state: suggestionState({ status: 'running' }),
        })
        .mockResolvedValueOnce({
          state: suggestionState({ suggestion_request_id: 'sr-3' }),
        });

      await copilot.startReplySuggestion();

      expect(mockCancelReplySuggestion).toHaveBeenCalledTimes(2);
      expect(mockStartReplySuggestion).toHaveBeenCalledTimes(3);
      expect(copilot.suggestionRequestId.value).toBe('sr-3');
      expect(copilot.suggestionNotice.value).toBeNull();
    });

    it('cancels while queued', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();
      expect(copilot.suggestionPhase.value).toBe('queued');

      copilot.cancelGeneration();

      expect(mockCancelReplySuggestion).toHaveBeenCalledTimes(1);
      expect(copilot.suggestionPhase.value).toBe('idle');
    });

    it('cancels before the 202 arrived: sends the cancel with the late id and stays idle', async () => {
      const copilot = create();
      let resolveStart;
      mockStartReplySuggestion.mockReturnValueOnce(
        new Promise(resolve => {
          resolveStart = resolve;
        })
      );
      const started = copilot.startReplySuggestion();
      expect(copilot.canCancel.value).toBe(true);

      copilot.cancelGeneration();
      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();

      resolveStart({ state: suggestionState() });
      await started;

      expect(mockCancelReplySuggestion).toHaveBeenCalledWith({
        conversationId: 42,
        suggestionRequestId: RUN,
      });
      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(copilot.suggestionRequestId.value).toBeNull();
      emitResult(draftState());
      expect(copilot.showEditor.value).toBe(false);
    });

    it('aborts a synchronous rewrite and closes the panel', async () => {
      const copilot = create();
      mockProcessEvent.mockImplementationOnce(
        (_type, _content, { signal }) =>
          new Promise(resolve => {
            signal.addEventListener('abort', () =>
              resolve({ message: '', errorType: 'aborted' })
            );
          })
      );

      const running = copilot.execute('improve', 'привет');
      expect(copilot.isGenerating.value).toBe(true);
      expect(copilot.canCancel.value).toBe(true);

      copilot.cancelGeneration();
      await running;

      expect(copilot.isGenerating.value).toBe(false);
      expect(copilot.isActive.value).toBe(false);
      expect(copilot.canCancel.value).toBe(false);
      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();
    });

    it('keeps the previous draft when a follow-up is cancelled', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot);
      mockFollowUp.mockImplementationOnce(
        ({ signal }) =>
          new Promise(resolve => {
            signal.addEventListener('abort', () =>
              resolve({ message: '', errorType: 'aborted' })
            );
          })
      );

      const refining = copilot.sendFollowUp('короче');
      expect(copilot.isGenerating.value).toBe(true);
      expect(copilot.canCancel.value).toBe(true);

      copilot.cancelGeneration();
      await refining;

      expect(copilot.isGenerating.value).toBe(false);
      expect(copilot.showEditor.value).toBe(true);
      expect(copilot.generatedContent.value).toBe(
        'Здравствуйте! Ближайшее окно к ЛОР-врачу завтра в 10:00.'
      );
      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();
    });

    it('stops a running suggestion on the server when another AI action replaces it', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ status: 'running' }),
      });
      await copilot.startReplySuggestion();
      mockProcessEvent.mockResolvedValueOnce({ message: 'Переписано.' });

      await copilot.execute('improve', 'привет');

      expect(mockCancelReplySuggestion).toHaveBeenCalledWith({
        conversationId: 42,
        suggestionRequestId: RUN,
      });
      expect(copilot.generatedContent.value).toBe('Переписано.');
      expect(copilot.suggestionPhase.value).toBe('idle');
      // the abandoned run cannot hijack the rewrite later
      emitResult(draftState());
      expect(copilot.generatedContent.value).toBe('Переписано.');
    });
  });

  describe('conversations never leak into each other', () => {
    it('drops the result of conversation 42 after switching to 99 and does not cancel the run', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();
      emitProgress(progressEvent());
      expect(copilot.suggestionPhase.value).toBe('generating');

      switchConversation(99);
      copilot.detach();

      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(copilot.isActive.value).toBe(false);
      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();
      expect(TasksAPI.feedback).not.toHaveBeenCalled();

      emitProgress(progressEvent());
      emitResult(draftState());
      emitResult(noticeState('no_reply'));
      emitResult(failedState());

      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.generatedContent.value).toBe('');
      expect(copilot.suggestionNotice.value).toBeNull();
      expect(copilot.isGenerating.value).toBe(false);
    });

    it('ignores the 202 of conversation 42 that arrives after switching to 99', async () => {
      const copilot = create();
      let resolveStart;
      mockStartReplySuggestion.mockReturnValueOnce(
        new Promise(resolve => {
          resolveStart = resolve;
        })
      );
      const started = copilot.startReplySuggestion();

      switchConversation(99);
      copilot.detach();
      resolveStart({ state: suggestionState({ status: 'running' }) });
      await started;

      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(copilot.isGenerating.value).toBe(false);
      expect(copilot.suggestionRequestId.value).toBeNull();
      // switching away is not a cancel
      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();
    });

    it('adopts events only for the open conversation', async () => {
      const copilot = create();
      switchConversation(99);

      emitProgress(progressEvent({ conversation_id: 42 }));
      expect(copilot.suggestionPhase.value).toBe('idle');
      emitResult(draftState());
      expect(copilot.showEditor.value).toBe(false);

      // a run started from another tab in the open conversation is followed
      emitProgress(
        progressEvent({
          suggestion_request_id: 'sr-99',
          conversation_id: 99,
        })
      );
      expect(copilot.suggestionPhase.value).toBe('generating');
      expect(copilot.suggestionRequestId.value).toBe('sr-99');

      emitResult(
        draftState({}, { suggestion_request_id: 'sr-99', conversation_id: 99 })
      );
      expect(copilot.showEditor.value).toBe(true);
    });

    it('does not adopt events when the composable is not set up to sync suggestions', () => {
      const copilot = create({ syncSuggestions: false });

      emitProgress(progressEvent());
      emitResult(draftState());

      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(copilot.showEditor.value).toBe(false);
    });

    it('does not adopt events while a rewrite is on screen', async () => {
      const copilot = create();
      mockProcessEvent.mockResolvedValueOnce({ message: 'Переписано.' });
      await copilot.execute('improve', 'привет');

      emitProgress(progressEvent());
      emitResult(draftState());

      expect(copilot.generatedContent.value).toBe('Переписано.');
      expect(copilot.suggestionPhase.value).toBe('idle');
    });

    it('drops an event of the followed run that names another conversation', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();

      emitResult(draftState({}, { conversation_id: 77 }));

      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.suggestionPhase.value).toBe('queued');
    });

    it('does not let a stale conversation drop pending actions of the new one', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot, { pending_actions: [sampleAction] });
      copilot.accept();
      expect(copilot.pendingActions.value).toEqual([sampleAction]);

      switchConversation(99);
      copilot.detach();
      expect(copilot.pendingActions.value).toEqual([]);

      switchConversation(42);
      expect(copilot.pendingActions.value).toEqual([sampleAction]);
    });
  });

  describe('restore after navigation', () => {
    it('brings back a running suggestion with its live progress and timing', async () => {
      const copilot = create();
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: suggestionState({
          status: 'running',
          started_at: '2026-10-24T09:12:03Z',
          deadline_at: '2026-10-24T09:13:03Z',
          progress: progressEvent({ pending_actions: [sampleAction] }),
        }),
      });

      await copilot.restoreForConversation();

      expect(mockGetReplySuggestionStatus).toHaveBeenCalledWith({
        conversationId: 42,
      });
      expect(copilot.suggestionPhase.value).toBe('generating');
      expect(copilot.isGenerating.value).toBe(true);
      expect(copilot.suggestionRequestId.value).toBe(RUN);
      expect(copilot.liveProgress.value.phase).toBe('thinking');
      expect(copilot.suggestionTiming.value.deadlineAt).toBe(
        Date.parse('2026-10-24T09:13:03Z')
      );
      expect(copilot.pendingActions.value).toEqual([sampleAction]);

      // and the result that follows lands in the editor
      emitResult(draftState());
      expect(copilot.showEditor.value).toBe(true);
    });

    it('brings back a queued suggestion', async () => {
      const copilot = create();
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: suggestionState({ status: 'queued' }),
      });

      await copilot.restoreForConversation();

      expect(copilot.suggestionPhase.value).toBe('queued');
      expect(copilot.isQueued.value).toBe(true);
    });

    it('brings back a finished draft as ready content with the stale flag', async () => {
      const copilot = create();
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draftState({}, { stale: true }),
      });

      await copilot.restoreForConversation();

      expect(copilot.suggestionPhase.value).toBe('draft');
      expect(copilot.showEditor.value).toBe(true);
      expect(copilot.generatedContent.value).toContain('Здравствуйте!');
      expect(copilot.suggestionStale.value).toBe(true);
      // no live transition will run, so the insert button must be usable
      expect(copilot.isContentReady.value).toBe(true);
      expect(copilot.isButtonDisabled.value).toBe(false);
      expect(copilot.canAccept.value).toBe(true);
      // restoring is not a new "used" event
      expect(useTrack).not.toHaveBeenCalled();
    });

    it.each([
      ['no_reply', 'no_reply'],
      ['human_needed', 'human_needed'],
    ])('brings back a %s notice', async (status, kind) => {
      const copilot = create();
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: noticeState(status, {}, { stale: true }),
      });

      await copilot.restoreForConversation();

      expect(copilot.suggestionPhase.value).toBe('notice');
      expect(copilot.suggestionNotice.value).toMatchObject({
        kind,
        stale: true,
      });
      expect(copilot.showEditor.value).toBe(false);
    });

    it('brings back a failed suggestion without reporting a new failure', async () => {
      const copilot = create();
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: failedState('provider_error'),
      });

      await copilot.restoreForConversation();

      expect(copilot.suggestionNotice.value).toMatchObject({
        kind: 'failed',
        reasonCode: 'provider_error',
        canRetry: true,
      });
      expect(useTrack).not.toHaveBeenCalled();
    });

    it.each([
      ['nothing to restore', { suggestion: null }],
      [
        'a cancelled run',
        { suggestion: suggestionState({ status: 'cancelled' }) },
      ],
      ['a failed request', { suggestion: null, failed: true }],
    ])('stays idle for %s', async (_name, answer) => {
      const copilot = create();
      mockGetReplySuggestionStatus.mockResolvedValueOnce(answer);

      await copilot.restoreForConversation();

      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(copilot.isActive.value).toBe(false);
      expect(copilot.suggestionNotice.value).toBeNull();
    });

    it('never applies a state that belongs to another conversation', async () => {
      const copilot = create();
      switchConversation(99);
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draftState({}, { conversation_id: 42 }),
      });

      await copilot.restoreForConversation();

      expect(mockGetReplySuggestionStatus).toHaveBeenCalledWith({
        conversationId: 99,
      });
      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.generatedContent.value).toBe('');
      expect(copilot.suggestionPhase.value).toBe('idle');
    });

    it('drops the answer when the manager left the conversation while it was loading', async () => {
      const copilot = create();
      let resolveStatus;
      mockGetReplySuggestionStatus.mockReturnValueOnce(
        new Promise(resolve => {
          resolveStatus = resolve;
        })
      );
      const restoring = copilot.restoreForConversation();

      switchConversation(99);
      copilot.detach();
      resolveStatus({ suggestion: draftState() });
      await restoring;

      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.generatedContent.value).toBe('');
      expect(copilot.suggestionPhase.value).toBe('idle');
    });

    it('drops the answer when the manager started something meanwhile', async () => {
      const copilot = create();
      let resolveStatus;
      mockGetReplySuggestionStatus.mockReturnValueOnce(
        new Promise(resolve => {
          resolveStatus = resolve;
        })
      );
      const restoring = copilot.restoreForConversation();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ suggestion_request_id: 'sr-new' }),
      });
      await copilot.startReplySuggestion();

      resolveStatus({ suggestion: draftState() });
      await restoring;

      expect(copilot.suggestionRequestId.value).toBe('sr-new');
      expect(copilot.showEditor.value).toBe(false);
    });

    it('does not restore when AI writing tools are switched off or syncing is not enabled', async () => {
      mockTextImprovementEnabled.value = false;
      const switchedOff = create();
      await switchedOff.restoreForConversation();

      mockTextImprovementEnabled.value = true;
      const notSyncing = create({ syncSuggestions: false });
      await notSyncing.restoreForConversation();

      expect(mockGetReplySuggestionStatus).not.toHaveBeenCalled();
    });

    it('survives a full round trip: leave 42, come back, see the draft that finished meanwhile', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();

      switchConversation(99);
      copilot.detach();
      await copilot.restoreForConversation();
      expect(copilot.suggestionPhase.value).toBe('idle');

      switchConversation(42);
      copilot.detach();
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draftState(),
      });
      await copilot.restoreForConversation();

      expect(mockGetReplySuggestionStatus).toHaveBeenLastCalledWith({
        conversationId: 42,
      });
      expect(copilot.showEditor.value).toBe(true);
      expect(copilot.generatedContent.value).toContain('Здравствуйте!');
    });
  });

  describe('watchdog and live timing', () => {
    beforeEach(() => {
      vi.useFakeTimers();
      vi.setSystemTime(new Date('2026-10-24T09:12:10Z'));
    });

    it('asks the API for the run after 15 s without events and applies the answer', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ status: 'running' }),
      });
      await copilot.startReplySuggestion();
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draftState(),
      });

      await vi.advanceTimersByTimeAsync(14000);
      expect(mockGetReplySuggestionStatus).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(1000);

      expect(mockGetReplySuggestionStatus).toHaveBeenCalledWith({
        conversationId: 42,
        suggestionRequestId: RUN,
      });
      expect(copilot.suggestionPhase.value).toBe('draft');
      expect(copilot.showEditor.value).toBe(true);
    });

    it('is re-armed by every event', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ status: 'running' }),
      });
      await copilot.startReplySuggestion();

      await vi.advanceTimersByTimeAsync(14000);
      emitProgress(progressEvent({ deadline_at: null }));
      await vi.advanceTimersByTimeAsync(14000);
      expect(mockGetReplySuggestionStatus).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(1000);
      expect(mockGetReplySuggestionStatus).toHaveBeenCalledTimes(1);
    });

    it('waits until the run deadline plus 20 s when that is later than 15 s', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({
          status: 'running',
          started_at: '2026-10-24T09:12:03Z',
          deadline_at: '2026-10-24T09:13:03Z',
        }),
      });
      await copilot.startReplySuggestion();

      // deadline (09:13:03) + 20 s = 09:13:23, that is 73 s from now
      await vi.advanceTimersByTimeAsync(72000);
      expect(mockGetReplySuggestionStatus).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(1000);
      expect(mockGetReplySuggestionStatus).toHaveBeenCalledTimes(1);
    });

    it('stops waiting with a failure when the server no longer knows the run', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ status: 'running' }),
      });
      await copilot.startReplySuggestion();
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: null,
        failed: true,
        notFound: true,
      });

      await vi.advanceTimersByTimeAsync(15000);

      expect(copilot.suggestionNotice.value).toMatchObject({
        kind: 'failed',
        reasonCode: 'interrupted',
        canRetry: true,
      });
    });

    it('keeps waiting after a network error', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ status: 'running' }),
      });
      await copilot.startReplySuggestion();
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: null,
        failed: true,
      });

      await vi.advanceTimersByTimeAsync(15000);
      expect(copilot.suggestionPhase.value).toBe('generating');

      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draftState(),
      });
      await vi.advanceTimersByTimeAsync(15000);
      expect(copilot.suggestionPhase.value).toBe('draft');
    });

    it('checks the run right after the socket reconnected', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ status: 'running' }),
      });
      await copilot.startReplySuggestion();
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draftState(),
      });

      emitter.emit(BUS_EVENTS.WEBSOCKET_RECONNECT_COMPLETED);
      await vi.advanceTimersByTimeAsync(0);

      expect(mockGetReplySuggestionStatus).toHaveBeenCalledWith({
        conversationId: 42,
        suggestionRequestId: RUN,
      });
      expect(copilot.showEditor.value).toBe(true);
    });

    it('does not poll when nothing is generating', async () => {
      create();

      emitter.emit(BUS_EVENTS.WEBSOCKET_RECONNECT_COMPLETED);
      await vi.advanceTimersByTimeAsync(120000);

      expect(mockGetReplySuggestionStatus).not.toHaveBeenCalled();
    });

    it('counts the elapsed seconds of a running suggestion', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({
          status: 'running',
          started_at: '2026-10-24T09:12:03Z',
        }),
      });
      await copilot.startReplySuggestion();
      expect(copilot.elapsedSeconds.value).toBe(7);

      await vi.advanceTimersByTimeAsync(3000);
      expect(copilot.elapsedSeconds.value).toBe(10);

      emitResult(draftState());
      expect(copilot.elapsedSeconds.value).toBeNull();
    });

    it('has no elapsed time while queued', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState({ status: 'queued' }),
      });
      await copilot.startReplySuggestion();

      expect(copilot.elapsedSeconds.value).toBeNull();
    });
  });

  describe('feedback', () => {
    it('sends applied with the suggestion request id and remembers it for the sent event', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot);

      const text = copilot.accept();

      expect(text).toContain('Здравствуйте!');
      expect(TasksAPI.feedback).toHaveBeenCalledTimes(1);
      expect(TasksAPI.feedback).toHaveBeenCalledWith(
        expect.objectContaining({
          conversationId: 42,
          requestId: RUN,
          suggestionRequestId: RUN,
          copilotAction: 'reply_suggestion',
          outcome: 'applied',
          generatedText: text,
        })
      );
      expect(copilot.lastAcceptedMeta.value).toMatchObject({
        requestId: RUN,
        suggestionRequestId: RUN,
        action: 'reply_suggestion',
        conversationId: 42,
      });
      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(copilot.showEditor.value).toBe(false);
    });

    it('does not bring an applied suggestion back when a repeat of the result arrives', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot);
      copilot.accept();

      emitResult(draftState());
      emitProgress(progressEvent());

      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.suggestionPhase.value).toBe('idle');
    });

    it('«Отклонить» sends dismissed with the suggestion request id and no extra fields', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot);

      copilot.dismiss();

      expect(TasksAPI.feedback).toHaveBeenCalledTimes(1);
      const payload = TasksAPI.feedback.mock.calls[0][0];
      expect(payload).toMatchObject({
        conversationId: 42,
        requestId: RUN,
        suggestionRequestId: RUN,
        copilotAction: 'reply_suggestion',
        outcome: 'dismissed',
        generatedText: expect.stringContaining('Здравствуйте!'),
      });
      expect(payload).not.toHaveProperty('correctAnswer');
      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.generatedContent.value).toBe('');
      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();

      // a dismissed suggestion does not return
      emitResult(draftState());
      expect(copilot.showEditor.value).toBe(false);
    });

    it('sends notice_dismissed when the notice is closed and does not show it again', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();
      emitResult(noticeState('human_needed'));

      copilot.dismissNotice();

      expect(TasksAPI.feedback).toHaveBeenCalledWith(
        expect.objectContaining({
          conversationId: 42,
          suggestionRequestId: RUN,
          copilotAction: 'reply_suggestion',
          outcome: 'notice_dismissed',
        })
      );
      expect(copilot.suggestionNotice.value).toBeNull();
      expect(copilot.suggestionPhase.value).toBe('idle');
      emitResult(noticeState('human_needed'));
      expect(copilot.suggestionNotice.value).toBeNull();
    });

    it('closes a start-error notice without any feedback call', async () => {
      const copilot = create();
      mockStartReplySuggestion.mockResolvedValueOnce({
        errorCode: 'voice_channel_unsupported',
        error: 'x',
        errorType: 'http_422',
      });
      await copilot.startReplySuggestion();

      copilot.dismissNotice();

      expect(TasksAPI.feedback).not.toHaveBeenCalled();
      expect(copilot.suggestionNotice.value).toBeNull();
    });

    it('reset() does not send dismissed for a reply suggestion, so the event is not duplicated', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot);

      copilot.reset();

      expect(TasksAPI.feedback).not.toHaveBeenCalled();
      expect(copilot.showEditor.value).toBe(false);
    });

    it('reset() still reports dismissed for a rewrite', async () => {
      const copilot = create();
      mockProcessEvent.mockResolvedValueOnce({
        message: 'Переписано.',
        requestId: 'req-rw',
      });
      await copilot.execute('improve', 'привет');

      copilot.reset();

      expect(TasksAPI.feedback).toHaveBeenCalledWith(
        expect.objectContaining({
          requestId: 'req-rw',
          copilotAction: 'improve',
          outcome: 'dismissed',
        })
      );
      expect(TasksAPI.feedback.mock.calls[0][0].suggestionRequestId).toBe(
        undefined
      );
    });

    it('detach() sends no feedback and no cancel', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot);

      copilot.detach();

      expect(TasksAPI.feedback).not.toHaveBeenCalled();
      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();
      expect(copilot.showEditor.value).toBe(false);
    });
  });

  describe('pending actions', () => {
    it('populates pendingActions from the draft and handles approveAction', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot, {
        message: 'Можем записать вас на 10:00.',
        pending_actions: [sampleAction],
      });

      expect(copilot.generatedContent.value).toBe(
        'Можем записать вас на 10:00.'
      );
      expect(copilot.pendingActions.value).toEqual([sampleAction]);

      TasksAPI.approveAction.mockResolvedValueOnce({
        data: {
          ok: true,
          status: 'approved',
          action: { ...sampleAction, status: 'approved' },
        },
      });

      await copilot.approveAction(sampleAction);

      expect(TasksAPI.approveAction).toHaveBeenCalledWith({
        actionId: 'act-55',
        conversationId: 42,
        digest: 'dig-55',
      });
      expect(copilot.pendingActions.value[0].status).toBe('approved');
    });

    it('updates action status to rejected when rejectAction is called', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot, {
        pending_actions: [{ ...sampleAction, action_id: 'act-56' }],
      });

      TasksAPI.rejectAction.mockResolvedValueOnce({
        data: {
          ok: true,
          status: 'rejected',
          action: { ...sampleAction, action_id: 'act-56', status: 'rejected' },
        },
      });

      await copilot.rejectAction({ ...sampleAction, action_id: 'act-56' });

      expect(TasksAPI.rejectAction).toHaveBeenCalledWith({
        actionId: 'act-56',
        conversationId: 42,
      });
      expect(copilot.pendingActions.value[0].status).toBe('rejected');
    });

    describe('when the server fails an action', () => {
      const RAW =
        "This service is not linked to the clinic's MedElement. Retry the call without service_id.";
      const FAILED = 'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_FAILED';
      const REJECT_FAILED =
        'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_REJECT_FAILED';
      const action = { ...sampleAction, action_id: 'act-57' };

      it('marks the card failed and tells the staff one plain line, not the server text', async () => {
        const copilot = create();
        await startAndReceiveDraft(copilot, { pending_actions: [action] });
        TasksAPI.approveAction.mockRejectedValueOnce({
          message: 'Request failed with status code 422',
          response: {
            data: {
              error: RAW,
              action: { ...action, status: 'failed', error_message: RAW },
            },
          },
        });

        const result = await copilot.approveAction(action);

        expect(result).toBeNull();
        expect(copilot.pendingActions.value[0].status).toBe('failed');
        expect(useAlert).toHaveBeenCalledTimes(1);
        expect(useAlert).toHaveBeenCalledWith(FAILED);
        expect(copilot.actionLoadingById.value).toEqual({});
      });

      it('does the same when the server gave no answer at all', async () => {
        const copilot = create();
        await startAndReceiveDraft(copilot, { pending_actions: [action] });
        TasksAPI.approveAction.mockRejectedValueOnce(
          new Error('Network Error')
        );

        await copilot.approveAction(action);

        expect(copilot.pendingActions.value[0].status).toBe('failed');
        expect(copilot.pendingActions.value[0].error_message).toBeUndefined();
        expect(useAlert).toHaveBeenCalledTimes(1);
        expect(useAlert).toHaveBeenCalledWith(FAILED);
      });

      it('tells a plain line when «Запретить» fails, and keeps the card as it was', async () => {
        const copilot = create();
        await startAndReceiveDraft(copilot, { pending_actions: [action] });
        TasksAPI.rejectAction.mockRejectedValueOnce({
          message: 'Request failed with status code 422',
          response: { data: { error: RAW } },
        });

        const result = await copilot.rejectAction(action);

        expect(result).toBeNull();
        expect(copilot.pendingActions.value[0].status).toBe('pending');
        expect(useAlert).toHaveBeenCalledTimes(1);
        expect(useAlert).toHaveBeenCalledWith(REJECT_FAILED);
      });
    });

    it('retains pendingActions after accept() and isolates them per conversation', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot, {
        message: 'Запишем вас на завтра.',
        pending_actions: [{ ...sampleAction, action_id: 'act-90' }],
      });

      const acceptedText = copilot.accept();

      expect(acceptedText).toBe('Запишем вас на завтра.');
      expect(copilot.showEditor.value).toBe(false);
      expect(copilot.pendingActions.value).toEqual([
        { ...sampleAction, action_id: 'act-90' },
      ]);

      // Switching to another conversation isolates pending actions
      switchConversation(99);
      copilot.detach();
      expect(copilot.pendingActions.value).toEqual([]);

      // Switching back to conversation 42 restores its unapproved action
      switchConversation(42);
      expect(copilot.pendingActions.value).toEqual([
        { ...sampleAction, action_id: 'act-90' },
      ]);
    });
  });

  describe('cards leave the panel', () => {
    const LINGER = 1500;
    const cardsOf = ids => ids.map(id => ({ ...sampleAction, action_id: id }));
    const idsOf = list => list.map(item => item.action_id);
    const answer = (status, id, extra = {}) => ({
      data: {
        ok: true,
        status,
        action: { ...sampleAction, action_id: id, status, ...extra },
      },
    });
    // the server answers every «Запретить» with the rejected card
    const rejectEverything = () =>
      TasksAPI.rejectAction.mockImplementation(({ actionId }) =>
        Promise.resolve(answer('rejected', actionId))
      );
    // lets the answers of the server arrive without moving the fake clock
    const flush = () => vi.advanceTimersByTimeAsync(0);

    // The run left only cards: no text for the patient
    const receiveCardsOnly = async (
      copilot,
      ids,
      status = 'no_reply',
      resultOverrides = {}
    ) => {
      mockStartReplySuggestion.mockResolvedValueOnce({
        state: suggestionState(),
      });
      await copilot.startReplySuggestion();
      emitResult(
        noticeState(status, {
          pending_actions: cardsOf(ids),
          ...resultOverrides,
        })
      );
    };

    beforeEach(() => {
      vi.useFakeTimers();
      TasksAPI.rejectAction.mockReset();
      TasksAPI.approveAction.mockReset();
    });

    it('keeps an approved card for 1.5 s with its result, then takes it off', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot, {
        pending_actions: cardsOf(['act-1', 'act-2']),
      });
      TasksAPI.approveAction.mockResolvedValueOnce(
        answer('approved', 'act-1', { result_summary: 'Д-р Смит — 10:00' })
      );

      await copilot.approveAction(cardsOf(['act-1'])[0]);

      expect(copilot.visibleActions.value[0]).toMatchObject({
        action_id: 'act-1',
        status: 'approved',
        result_summary: 'Д-р Смит — 10:00',
      });
      vi.advanceTimersByTime(LINGER - 1);
      expect(idsOf(copilot.visibleActions.value)).toEqual(['act-1', 'act-2']);

      vi.advanceTimersByTime(1);
      expect(idsOf(copilot.visibleActions.value)).toEqual(['act-2']);
      // the card is only marked: nothing can bring it back
      expect(copilot.pendingActions.value[0]).toMatchObject({
        action_id: 'act-1',
        dismissed: true,
      });
    });

    it('does the same with a denied card', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot, {
        pending_actions: cardsOf(['act-1']),
      });
      TasksAPI.rejectAction.mockResolvedValueOnce(answer('rejected', 'act-1'));

      await copilot.rejectAction(cardsOf(['act-1'])[0]);

      expect(copilot.visibleActions.value[0].status).toBe('rejected');
      vi.advanceTimersByTime(LINGER);
      expect(copilot.visibleActions.value).toEqual([]);
      expect(copilot.openActions.value).toEqual([]);
    });

    it('keeps a failed card until the manager closes it', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot, {
        pending_actions: cardsOf(['act-1']),
      });
      TasksAPI.approveAction.mockRejectedValueOnce(new Error('Network Error'));

      await copilot.approveAction(cardsOf(['act-1'])[0]);
      vi.advanceTimersByTime(60000);

      expect(copilot.visibleActions.value[0].status).toBe('failed');
      expect(copilot.openActions.value).toHaveLength(1);

      copilot.closeAction(copilot.visibleActions.value[0]);

      expect(copilot.visibleActions.value).toEqual([]);
      expect(TasksAPI.rejectAction).not.toHaveBeenCalled();
    });

    it('lets a failed card be approved again and leave after its result', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot, {
        pending_actions: cardsOf(['act-1']),
      });
      TasksAPI.approveAction
        .mockRejectedValueOnce(new Error('Network Error'))
        .mockResolvedValueOnce(answer('approved', 'act-1'));

      await copilot.approveAction(cardsOf(['act-1'])[0]);
      await copilot.approveAction(cardsOf(['act-1'])[0]);
      vi.advanceTimersByTime(LINGER);

      expect(copilot.visibleActions.value).toEqual([]);
    });

    it('stops the waiting cards when the owner goes away', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot, {
        pending_actions: cardsOf(['act-1']),
      });
      TasksAPI.approveAction.mockResolvedValueOnce(answer('approved', 'act-1'));
      await copilot.approveAction(cardsOf(['act-1'])[0]);
      expect(vi.getTimerCount()).toBe(1);

      scopes.splice(0).forEach(scope => scope.stop());

      expect(vi.getTimerCount()).toBe(0);
    });

    describe('when the run left only cards', () => {
      it('takes the place of the editor while a card waits for a decision', async () => {
        const copilot = create();

        await receiveCardsOnly(copilot, ['act-1', 'act-2']);

        expect(copilot.suggestionPhase.value).toBe('notice');
        expect(copilot.isActive.value).toBe(false);
        expect(copilot.isActionsOnly.value).toBe(true);
        expect(copilot.editorTransitionKey.value).toBe('copilot');
        expect(idsOf(copilot.openActions.value)).toEqual(['act-1', 'act-2']);
      });

      it('goes back to the editor when the last card has left', async () => {
        const copilot = create();
        await receiveCardsOnly(copilot, ['act-1', 'act-2']);
        TasksAPI.approveAction.mockResolvedValueOnce(
          answer('approved', 'act-1')
        );
        TasksAPI.rejectAction.mockResolvedValueOnce(
          answer('rejected', 'act-2')
        );

        await copilot.approveAction(cardsOf(['act-1'])[0]);
        await copilot.rejectAction(cardsOf(['act-2'])[0]);

        // both decided, both still shown for a moment: nothing to cancel any more
        expect(copilot.openActions.value).toEqual([]);
        expect(copilot.isActionsOnly.value).toBe(true);

        vi.advanceTimersByTime(LINGER);

        expect(copilot.visibleActions.value).toEqual([]);
        expect(copilot.isActionsOnly.value).toBe(false);
        expect(copilot.editorTransitionKey.value).toBe('rich');
        // the notice above the reply box has its own «Скрыть»
        expect(copilot.suggestionPhase.value).toBe('notice');
        expect(copilot.suggestionNotice.value.kind).toBe('no_reply');
      });

      it('«Отменить» declines every undecided card and closes the panel', async () => {
        const copilot = create();
        await receiveCardsOnly(copilot, ['act-1', 'act-2', 'act-3']);
        rejectEverything();
        // act-1 was decided a moment ago and still waits to leave
        await copilot.rejectAction(cardsOf(['act-1'])[0]);
        TasksAPI.rejectAction.mockClear();

        copilot.dismiss();
        await flush();

        expect(TasksAPI.rejectAction.mock.calls.map(([args]) => args)).toEqual([
          { actionId: 'act-2', conversationId: 42 },
          { actionId: 'act-3', conversationId: 42 },
        ]);
        expect(copilot.visibleActions.value).toEqual([]);
        expect(copilot.isActionsOnly.value).toBe(false);
        // no waiting card is left behind
        expect(vi.getTimerCount()).toBe(0);
        // the notice and the run stay: it is not a dropped draft
        expect(copilot.suggestionPhase.value).toBe('notice');
        expect(TasksAPI.feedback).not.toHaveBeenCalled();
      });

      it('keeps a card the server could not decline, with the alert', async () => {
        const copilot = create();
        await receiveCardsOnly(copilot, ['act-1', 'act-2']);
        TasksAPI.rejectAction
          .mockResolvedValueOnce(answer('rejected', 'act-1'))
          .mockRejectedValueOnce(new Error('Network Error'));

        copilot.dismiss();
        await flush();

        expect(idsOf(copilot.visibleActions.value)).toEqual(['act-2']);
        expect(copilot.visibleActions.value[0].status).toBe('pending');
        expect(copilot.isActionsOnly.value).toBe(true);
        expect(useAlert).toHaveBeenCalledWith(
          'CONVERSATION.REPLYBOX.COPILOT_TRACE.ACTION_REJECT_FAILED'
        );
      });

      it('lets a failed card stay open for «Отменить» too', async () => {
        const copilot = create();
        await receiveCardsOnly(copilot, ['act-1']);
        TasksAPI.approveAction.mockRejectedValueOnce(new Error('offline'));
        await copilot.approveAction(cardsOf(['act-1'])[0]);
        rejectEverything();

        copilot.dismiss();
        await flush();

        expect(TasksAPI.rejectAction).toHaveBeenCalledTimes(1);
        expect(copilot.visibleActions.value).toEqual([]);
      });

      it('is over when the notice is hidden: the cards stay beside the editor', async () => {
        const copilot = create();
        await receiveCardsOnly(copilot, ['act-1']);

        copilot.dismissNotice();

        expect(copilot.isActionsOnly.value).toBe(false);
        expect(idsOf(copilot.visibleActions.value)).toEqual(['act-1']);
      });
    });

    describe('when the editor must stay', () => {
      it('keeps it when a staff reply is needed, the cards are decided one by one', async () => {
        const copilot = create();

        await receiveCardsOnly(copilot, ['act-1'], 'human_needed');

        expect(copilot.suggestionNotice.value.kind).toBe('human_needed');
        expect(copilot.isActionsOnly.value).toBe(false);
        expect(copilot.editorTransitionKey.value).toBe('rich');
        expect(idsOf(copilot.visibleActions.value)).toEqual(['act-1']);

        TasksAPI.rejectAction.mockResolvedValueOnce(
          answer('rejected', 'act-1')
        );
        await copilot.rejectAction(cardsOf(['act-1'])[0]);
        vi.advanceTimersByTime(LINGER);
        expect(copilot.visibleActions.value).toEqual([]);
      });

      it('keeps it when the text of the draft was inserted and the cards remain', async () => {
        const copilot = create();
        await startAndReceiveDraft(copilot, {
          pending_actions: cardsOf(['act-1']),
        });

        copilot.accept();

        expect(copilot.isActionsOnly.value).toBe(false);
        expect(idsOf(copilot.visibleActions.value)).toEqual(['act-1']);
      });
    });

    describe('«Отменить» of a draft', () => {
      it('declines the cards that wait for a decision and drops the draft', async () => {
        const copilot = create();
        await startAndReceiveDraft(copilot, {
          pending_actions: cardsOf(['act-1', 'act-2']),
        });
        rejectEverything();

        copilot.dismiss();
        await flush();

        expect(TasksAPI.rejectAction.mock.calls.map(([args]) => args)).toEqual([
          { actionId: 'act-1', conversationId: 42 },
          { actionId: 'act-2', conversationId: 42 },
        ]);
        expect(copilot.showEditor.value).toBe(false);
        expect(copilot.pendingActions.value).toEqual([]);
        expect(TasksAPI.feedback).toHaveBeenCalledWith(
          expect.objectContaining({ outcome: 'dismissed' })
        );
      });

      it('leaves the cards that were decided already alone', async () => {
        const copilot = create();
        await startAndReceiveDraft(copilot, {
          pending_actions: cardsOf(['act-1', 'act-2']),
        });
        TasksAPI.approveAction.mockResolvedValueOnce(
          answer('approved', 'act-1')
        );
        await copilot.approveAction(cardsOf(['act-1'])[0]);
        rejectEverything();

        copilot.dismiss();
        await flush();

        expect(TasksAPI.rejectAction.mock.calls.map(([args]) => args)).toEqual([
          { actionId: 'act-2', conversationId: 42 },
        ]);
      });
    });
  });

  describe('synchronous actions', () => {
    it('keeps rewrite working without touching the suggestion state', async () => {
      const copilot = create();
      mockProcessEvent.mockResolvedValueOnce({
        message: 'Исправленный текст.',
        followUpContext: { event_name: 'improve' },
        requestId: 'req-1',
      });

      await copilot.execute('improve', 'исправляй текст');

      expect(mockProcessEvent).toHaveBeenCalledWith(
        'improve',
        'исправляй текст',
        expect.objectContaining({ signal: expect.any(AbortSignal) })
      );
      expect(copilot.showEditor.value).toBe(true);
      expect(copilot.generatedContent.value).toBe('Исправленный текст.');
      expect(copilot.suggestionPhase.value).toBe('idle');
      expect(mockStartReplySuggestion).not.toHaveBeenCalled();
    });

    it('lets the follow-up replace the draft text of a suggestion', async () => {
      const copilot = create();
      await startAndReceiveDraft(copilot);
      mockFollowUp.mockResolvedValueOnce({
        message: 'Коротко: завтра в 10:00.',
        followUpContext: { event_name: 'reply_suggestion', n: 2 },
        requestId: 'req-2',
      });

      await copilot.sendFollowUp('короче');

      expect(copilot.generatedContent.value).toBe('Коротко: завтра в 10:00.');
      expect(copilot.suggestionPhase.value).toBe('draft');
      expect(copilot.suggestionRequestId.value).toBe(RUN);
      expect(copilot.requestId.value).toBe('req-2');
      expect(copilot.isGenerating.value).toBe(false);
    });
  });
});
