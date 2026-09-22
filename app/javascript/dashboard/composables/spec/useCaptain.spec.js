import { useCaptain } from '../useCaptain';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { useConfig } from 'dashboard/composables/useConfig';
import { useI18n } from 'vue-i18n';

vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables/useAccount');
vi.mock('dashboard/composables/useConfig');
vi.mock('vue-i18n');

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
    const { captainEnabled } = useCaptain();

    expect(captainEnabled.value).toBe(true);
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
});
