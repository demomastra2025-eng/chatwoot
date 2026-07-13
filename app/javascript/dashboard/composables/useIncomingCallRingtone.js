import { computed, onUnmounted, watch } from 'vue';

import { useUISettings } from 'dashboard/composables/useUISettings';
import IncomingCallRingtone from 'dashboard/helper/AudioAlerts/IncomingCallRingtone';
import { resolveIncomingCallRingtone } from 'dashboard/helper/AudioAlerts/ringtone';

export const useIncomingCallRingtone = (sourceId, isActive) => {
  const { uiSettings } = useUISettings();
  const selectedTone = computed(() =>
    resolveIncomingCallRingtone(uiSettings.value?.incoming_call_ringtone)
  );

  watch(
    [isActive, selectedTone],
    ([active, tone]) => {
      IncomingCallRingtone.setSourceState(sourceId, { active, tone });
    },
    { immediate: true }
  );

  onUnmounted(() => {
    IncomingCallRingtone.removeSource(sourceId);
  });
};
