import { effectScope, ref } from 'vue';
import { flushPromises } from '@vue/test-utils';
import { API } from 'widget/helpers/axios';
import { useAvailability } from '../useAvailability';

vi.mock('widget/helpers/axios', () => ({ API: { get: vi.fn() } }));

const scopes = [];
const useScopedAvailability = agents => {
  const scope = effectScope();
  scopes.push(scope);
  return scope.run(() => useAvailability(agents));
};
const projection = {
  configured: true,
  timezone: 'Asia/Almaty',
  intervals: [
    { starts_at: '2026-09-07T04:00:00Z', ends_at: '2026-09-07T07:00:00Z' },
    { starts_at: '2026-09-07T08:00:00Z', ends_at: '2026-09-07T12:00:00Z' },
  ],
};

describe('useAvailability', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-09-07T06:59:59Z'));
    window.chatwootWebChannel = {
      websiteToken: 'public-widget',
      workspaceAvailability: structuredClone(projection),
      replyTime: 'in_a_day',
      // Old channel settings must not override the company policy.
      workingHoursEnabled: false,
      workingHours: [],
      timezone: 'America/New_York',
    };
    API.get.mockResolvedValue({ data: projection });
  });

  afterEach(() => {
    scopes.splice(0).forEach(scope => scope.stop());
    vi.useRealTimers();
    delete window.chatwootWebChannel;
  });

  it('uses company availability and reactive agents', () => {
    const agents = ref([{ id: 1 }]);
    const availability = useScopedAvailability(agents);
    expect(availability.inboxConfig.value).toMatchObject({
      timezone: 'Asia/Almaty',
      workingHoursEnabled: true,
      replyTime: 'in_a_day',
    });
    expect(availability.isOnline.value).toBe(true);
    agents.value = [];
    expect(availability.hasOnlineAgents.value).toBe(false);
    expect(availability.isOnline.value).toBe(false);
    expect(availability.isInWorkingHours.value).toBe(true);
  });

  it('updates at lunch and reopening without a remount or network response', async () => {
    const availability = useScopedAvailability([{ id: 1 }]);
    await vi.advanceTimersByTimeAsync(1000);
    expect(availability.isInWorkingHours.value).toBe(false);
    expect(availability.isOnline.value).toBe(false);
    vi.setSystemTime(new Date('2026-09-07T08:00:00Z'));
    await vi.advanceTimersByTimeAsync(1000);
    expect(availability.isOnline.value).toBe(true);
  });

  it('shares one refresh loop between consumers and stops after disposal', async () => {
    const first = useScopedAvailability();
    const second = useScopedAvailability();
    expect(first.currentTime).toBe(second.currentTime);
    await vi.advanceTimersByTimeAsync(60000);
    expect(API.get).toHaveBeenCalledTimes(1);
    expect(API.get).toHaveBeenCalledWith('/api/v1/widget/availability', {
      params: { website_token: 'public-widget' },
    });
    scopes.splice(0).forEach(scope => scope.stop());
    await vi.advanceTimersByTimeAsync(120000);
    expect(API.get).toHaveBeenCalledTimes(1);
  });

  it('refreshes changed holidays on focus and retains the projection on network failure', async () => {
    const availability = useScopedAvailability([{ id: 1 }]);
    API.get.mockResolvedValueOnce({ data: { ...projection, intervals: [] } });
    window.dispatchEvent(new Event('focus'));
    await flushPromises();
    expect(availability.isOnline.value).toBe(false);
    API.get.mockRejectedValueOnce(new Error('offline'));
    window.dispatchEvent(new Event('focus'));
    await flushPromises();
    expect(availability.isOnline.value).toBe(false);
  });

  it('loads the server projection if the initial payload is missing', async () => {
    delete window.chatwootWebChannel.workspaceAvailability;
    const availability = useScopedAvailability([{ id: 1 }]);
    expect(availability.isOnline.value).toBe(false);
    await flushPromises();
    expect(availability.isOnline.value).toBe(true);
    expect(API.get).toHaveBeenCalledTimes(1);
  });

  it('does not invent availability after all projected intervals expire', () => {
    vi.setSystemTime(new Date('2026-09-21T12:00:00Z'));
    expect(useScopedAvailability([{ id: 1 }]).isOnline.value).toBe(false);
  });

  it('remains open with online agents if the company has no configured hours', () => {
    window.chatwootWebChannel.workspaceAvailability = {
      ...projection,
      configured: false,
      intervals: [
        { starts_at: '2026-09-07T00:00:00Z', ends_at: '2026-09-21T00:00:00Z' },
      ],
    };
    const availability = useScopedAvailability([{ id: 1 }]);
    expect(availability.inboxConfig.value.workingHoursEnabled).toBe(false);
    expect(availability.isOnline.value).toBe(true);
  });
});
