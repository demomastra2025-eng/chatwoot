import { computed, ref, unref } from 'vue';
import {
  createSharedComposable,
  useEventListener,
  useIntervalFn,
  useNow,
} from '@vueuse/core';
import { API } from 'widget/helpers/axios';
import { isWithinAvailability } from 'widget/helpers/workspaceAvailability';

// One clock and refresh loop for the header and availability text together.
const useWorkspaceAvailability = createSharedComposable(() => {
  const snapshot = ref(window.chatwootWebChannel?.workspaceAvailability);
  const currentTime = useNow({ interval: 1000 });
  let fetching = false;

  const refresh = async () => {
    const websiteToken = window.chatwootWebChannel?.websiteToken;
    if (fetching || !websiteToken) return;
    fetching = true;
    try {
      const { data } = await API.get('/api/v1/widget/availability', {
        params: { website_token: websiteToken },
      });
      snapshot.value = data;
    } catch {
      // Keep the last server projection during a temporary network failure.
      // Expired intervals naturally stop reporting availability.
    } finally {
      fetching = false;
    }
  };

  useIntervalFn(refresh, 60000);
  useEventListener(window, 'focus', refresh);
  if (!snapshot.value) refresh();
  return { snapshot, currentTime };
});

export function useAvailability(agents = []) {
  const { snapshot, currentTime } = useWorkspaceAvailability();
  const availableAgents = computed(() => unref(agents));
  const channelConfig = computed(() => window.chatwootWebChannel || {});
  const inboxConfig = computed(() => ({
    workingHours: snapshot.value?.intervals || [],
    workingHoursEnabled: snapshot.value?.configured || false,
    timezone: snapshot.value?.timezone || 'UTC',
    utcOffset: snapshot.value?.timezone || 'UTC',
    replyTime: channelConfig.value.replyTime || 'in_a_few_minutes',
  }));
  const hasOnlineAgents = computed(() => {
    const agentList = availableAgents.value || [];
    return Array.isArray(agentList) && agentList.length > 0;
  });
  const isInWorkingHours = computed(() =>
    isWithinAvailability(currentTime.value, inboxConfig.value.workingHours)
  );
  const isOnline = computed(
    () => isInWorkingHours.value && hasOnlineAgents.value
  );

  return {
    channelConfig,
    inboxConfig,
    currentTime,
    availableAgents,
    hasOnlineAgents,
    isOnline,
    isInWorkingHours,
  };
}
