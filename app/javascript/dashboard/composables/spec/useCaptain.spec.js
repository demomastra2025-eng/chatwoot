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

  it('gets reply suggestion', async () => {
    TasksAPI.replySuggestion.mockResolvedValue({
      data: { message: 'Reply suggestion', follow_up_context: { id: 'ctx3' } },
    });

    const { getReplySuggestion } = useCaptain();
    const result = await getReplySuggestion({});

    expect(TasksAPI.replySuggestion).toHaveBeenCalledWith('123', undefined);
    expect(result).toEqual({
      message: 'Reply suggestion',
      followUpContext: { id: 'ctx3' },
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
      data: { message: 'Reply' },
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
