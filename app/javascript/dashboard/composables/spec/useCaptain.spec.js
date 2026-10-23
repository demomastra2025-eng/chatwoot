import { useCaptain } from '../useCaptain';
import {
  useFunctionGetter,
  useMapGetter,
  useStore,
} from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { useConfig } from 'dashboard/composables/useConfig';
import { useI18n } from 'vue-i18n';
import TasksAPI from 'dashboard/api/captain/tasks';
import { useAlert } from 'dashboard/composables';

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));
vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables/useAccount');
vi.mock('dashboard/composables/useConfig');
vi.mock('vue-i18n');
vi.mock('dashboard/api/captain/tasks');
vi.mock('dashboard/helper/AnalyticsHelper/index', async importOriginal => {
  const actual = await importOriginal();
  actual.default = {
    track: vi.fn(),
  };
  return actual;
});
vi.mock('dashboard/helper/AnalyticsHelper/events', () => ({
  CAPTAIN_EVENTS: {
    TEST_EVENT: 'captain_test_event',
  },
}));

describe('useCaptain', () => {
  const mockStore = {
    dispatch: vi.fn(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
    useStore.mockReturnValue(mockStore);
    useFunctionGetter.mockReturnValue({ value: 'Draft message' });
    useMapGetter.mockImplementation(getter => {
      const mockValues = {
        'accounts/getUIFlags': { isFetchingLimits: false },
        getSelectedChat: { id: '123' },
        'draftMessages/getReplyEditorMode': 'reply',
      };
      return { value: mockValues[getter] };
    });
    useI18n.mockReturnValue({ t: vi.fn() });
    useAccount.mockReturnValue({
      isCloudFeatureEnabled: vi.fn().mockReturnValue(true),
      currentAccount: { value: { limits: { captain: {} } } },
    });
    useConfig.mockReturnValue({
      isEnterprise: false,
    });
  });

  it('initializes computed properties correctly', async () => {
    const { captainEnabled, captainTasksEnabled, currentChat, draftMessage } =
      useCaptain();

    expect(captainEnabled.value).toBe(true);
    expect(captainTasksEnabled.value).toBe(true);
    expect(currentChat.value).toEqual({ id: '123' });
    expect(draftMessage.value).toBe('Draft message');
  });

  describe('captainTextImprovementEnabled', () => {
    const mockAccount = ({ tasksFlag = true, captainFeatures } = {}) => {
      useAccount.mockReturnValue({
        isCloudFeatureEnabled: vi.fn().mockReturnValue(tasksFlag),
        currentAccount: {
          value: {
            limits: { captain: {} },
            settings:
              captainFeatures === undefined
                ? {}
                : { captain_features: captainFeatures },
          },
        },
      });
    };

    it('keeps the AI writing tools on when the account never set the switch', () => {
      mockAccount();

      expect(useCaptain().captainTextImprovementEnabled.value).toBe(true);
    });

    it('keeps the AI writing tools on when the switch is on', () => {
      mockAccount({ captainFeatures: { text_improvement: true } });

      expect(useCaptain().captainTextImprovementEnabled.value).toBe(true);
    });

    it('turns the AI writing tools off when an admin switched text improvement off', () => {
      mockAccount({
        captainFeatures: { text_improvement: false, label_suggestion: true },
      });

      const { captainTasksEnabled, captainTextImprovementEnabled } =
        useCaptain();

      expect(captainTextImprovementEnabled.value).toBe(false);
      expect(captainTasksEnabled.value).toBe(true);
    });

    // The old per-feature AI settings switch (2026-01..05) stored editor.
    it('ignores a legacy editor=false stored by the old per-feature switch', () => {
      mockAccount({ captainFeatures: { editor: false } });

      expect(useCaptain().captainTextImprovementEnabled.value).toBe(true);
    });

    it('stays off when the captain_tasks feature flag is off', () => {
      mockAccount({
        tasksFlag: false,
        captainFeatures: { text_improvement: true },
      });

      expect(useCaptain().captainTextImprovementEnabled.value).toBe(false);
    });
  });

  it('returns token limits and dispatches limits fetch in cloud enterprise mode', async () => {
    useAccount.mockReturnValue({
      isCloudFeatureEnabled: vi.fn().mockReturnValue(true),
      isOnChatwootCloud: { value: true },
      currentAccount: {
        value: {
          limits: {
            captain: {
              tokens: {
                total_count: 1200,
                current_available: 900,
                consumed: 300,
                unlimited: false,
              },
            },
          },
        },
      },
    });
    useConfig.mockReturnValue({
      isEnterprise: true,
    });
    mockStore.dispatch.mockResolvedValue();

    const { tokenLimits, fetchLimits } = useCaptain();
    await fetchLimits();

    expect(tokenLimits.value).toEqual({
      totalCount: 1200,
      currentAvailable: 900,
      consumed: 300,
      unlimited: false,
    });
    expect(mockStore.dispatch).toHaveBeenCalledWith('accounts/limits', {
      silent: true,
    });
  });

  it('rewrites content', async () => {
    TasksAPI.rewrite.mockResolvedValue({
      data: { message: 'Rewritten content', follow_up_context: { id: 'ctx1' } },
    });

    const { rewriteContent } = useCaptain();
    const result = await rewriteContent('Original content', 'improve', {});

    expect(TasksAPI.rewrite).toHaveBeenCalledWith(
      {
        content: 'Original content',
        operation: 'improve',
        conversationId: '123',
      },
      undefined
    );
    expect(result).toEqual({
      message: 'Rewritten content',
      followUpContext: { id: 'ctx1' },
    });
  });

  it('summarizes conversation', async () => {
    TasksAPI.summarize.mockResolvedValue({
      data: { message: 'Summary', follow_up_context: { id: 'ctx2' } },
    });

    const { summarizeConversation } = useCaptain();
    const result = await summarizeConversation({});

    expect(TasksAPI.summarize).toHaveBeenCalledWith('123', undefined);
    expect(result).toEqual({
      message: 'Summary',
      followUpContext: { id: 'ctx2' },
    });
  });

  describe('reply suggestion background run', () => {
    const queuedState = {
      suggestion_request_id: 'sr-1',
      status: 'queued',
      reused: false,
      engine: 'agent',
      conversation_id: 123,
      created_at: '2026-10-24T09:12:03Z',
      budget_seconds: 60,
      stale: false,
      progress: null,
      result: null,
    };

    it('starts a run and returns the 202 state without waiting for a draft', async () => {
      TasksAPI.replySuggestion.mockResolvedValue({
        status: 202,
        data: queuedState,
      });

      const { startReplySuggestion } = useCaptain();
      const result = await startReplySuggestion({});

      expect(TasksAPI.replySuggestion).toHaveBeenCalledWith('123', undefined);
      expect(result).toEqual({ state: queuedState });
    });

    it('starts the run for the conversation it is given', async () => {
      TasksAPI.replySuggestion.mockResolvedValue({ data: queuedState });

      const { startReplySuggestion } = useCaptain();
      await startReplySuggestion({ conversationId: 456 });

      expect(TasksAPI.replySuggestion).toHaveBeenCalledWith(456, undefined);
    });

    it('returns the error code and text of a refused request and shows no alert', async () => {
      TasksAPI.replySuggestion.mockRejectedValue({
        response: {
          status: 422,
          data: {
            error: 'В звонке нельзя отправить текст.',
            error_code: 'voice_channel_unsupported',
          },
        },
      });

      const { startReplySuggestion } = useCaptain();
      const result = await startReplySuggestion({});

      expect(result).toEqual({
        errorCode: 'voice_channel_unsupported',
        error: 'В звонке нельзя отправить текст.',
        errorType: 'http_422',
      });
      expect(useAlert).not.toHaveBeenCalled();
    });

    it('returns an error for a transport failure and for a body without a request id', async () => {
      const { startReplySuggestion } = useCaptain();

      TasksAPI.replySuggestion.mockRejectedValueOnce(new Error('Network'));
      expect(await startReplySuggestion({})).toEqual({
        errorCode: null,
        error: null,
        errorType: 'api_error',
      });

      TasksAPI.replySuggestion.mockResolvedValueOnce({
        data: { message: 'old synchronous body' },
      });
      expect(await startReplySuggestion({})).toEqual({
        errorCode: null,
        error: null,
        errorType: 'api_error',
      });
      expect(useAlert).not.toHaveBeenCalled();
    });

    it('reads the latest state of the open conversation', async () => {
      TasksAPI.replySuggestionStatus.mockResolvedValue({
        data: { suggestion: { ...queuedState, status: 'running' } },
      });

      const { getReplySuggestionStatus } = useCaptain();
      const result = await getReplySuggestionStatus();

      expect(TasksAPI.replySuggestionStatus).toHaveBeenCalledWith(
        { conversationId: '123', suggestionRequestId: undefined },
        undefined
      );
      expect(result.suggestion.status).toBe('running');
    });

    it('reads a specific run of a given conversation', async () => {
      TasksAPI.replySuggestionStatus.mockResolvedValue({
        data: { suggestion: queuedState },
      });

      const { getReplySuggestionStatus } = useCaptain();
      await getReplySuggestionStatus({
        conversationId: 456,
        suggestionRequestId: 'sr-1',
      });

      expect(TasksAPI.replySuggestionStatus).toHaveBeenCalledWith(
        { conversationId: 456, suggestionRequestId: 'sr-1' },
        undefined
      );
    });

    it('returns null for an empty answer and flags failures and unknown runs', async () => {
      const { getReplySuggestionStatus } = useCaptain();

      TasksAPI.replySuggestionStatus.mockResolvedValueOnce({
        data: { suggestion: null },
      });
      expect(await getReplySuggestionStatus()).toEqual({ suggestion: null });

      TasksAPI.replySuggestionStatus.mockRejectedValueOnce({
        response: { status: 404 },
      });
      expect(await getReplySuggestionStatus()).toEqual({
        suggestion: null,
        failed: true,
        notFound: true,
      });

      TasksAPI.replySuggestionStatus.mockRejectedValueOnce(new Error('x'));
      expect(await getReplySuggestionStatus()).toEqual({
        suggestion: null,
        failed: true,
        notFound: false,
      });
    });

    it('cancels a run and never throws', async () => {
      const { cancelReplySuggestion } = useCaptain();

      TasksAPI.cancelReplySuggestion.mockResolvedValueOnce({
        data: { suggestion_request_id: 'sr-1', status: 'cancelling' },
      });
      expect(
        await cancelReplySuggestion({ suggestionRequestId: 'sr-1' })
      ).toEqual({ ok: true, status: 'cancelling' });
      expect(TasksAPI.cancelReplySuggestion).toHaveBeenCalledWith({
        conversationId: '123',
        suggestionRequestId: 'sr-1',
      });

      TasksAPI.cancelReplySuggestion.mockRejectedValueOnce(new Error('x'));
      expect(
        await cancelReplySuggestion({
          conversationId: 7,
          suggestionRequestId: 'sr-2',
        })
      ).toEqual({ ok: false });
    });
  });

  it('sends follow-up message', async () => {
    TasksAPI.followUp.mockResolvedValue({
      data: {
        message: 'Follow-up response',
        follow_up_context: { id: 'ctx4' },
      },
    });

    const { followUp } = useCaptain();
    const result = await followUp({
      followUpContext: { id: 'ctx3' },
      message: 'Make it shorter',
    });

    expect(TasksAPI.followUp).toHaveBeenCalledWith(
      {
        followUpContext: { id: 'ctx3' },
        message: 'Make it shorter',
        conversationId: '123',
      },
      undefined
    );
    expect(result).toEqual({
      message: 'Follow-up response',
      followUpContext: { id: 'ctx4' },
    });
  });

  it('processes event and routes to correct method', async () => {
    TasksAPI.summarize.mockResolvedValue({
      data: { message: 'Summary' },
    });
    TasksAPI.replySuggestion.mockResolvedValue({
      data: { suggestion_request_id: 'sr-1', status: 'queued' },
    });
    TasksAPI.rewrite.mockResolvedValue({
      data: { message: 'Rewritten' },
    });

    const { processEvent } = useCaptain();

    // Test summarize
    await processEvent('summarize', '', {});
    expect(TasksAPI.summarize).toHaveBeenCalled();

    // Test reply_suggestion
    await processEvent('reply_suggestion', '', {});
    expect(TasksAPI.replySuggestion).toHaveBeenCalled();

    // Test rewrite (improve)
    await processEvent('improve', 'content', {});
    expect(TasksAPI.rewrite).toHaveBeenCalled();
  });
});
