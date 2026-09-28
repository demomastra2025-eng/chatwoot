import { computed, onUnmounted, watch } from 'vue';

import { useUISettings } from 'dashboard/composables/useUISettings';
import IncomingCallRingtone from 'dashboard/helper/AudioAlerts/IncomingCallRingtone';
import { resolveIncomingCallRingtone } from 'dashboard/helper/AudioAlerts/ringtone';

export const useIncomingCallRingtone = (sourceId, isActive) => {
  const { uiSettings } = useUISettings();
  const selectedTone = computed(() =>
    resolveIncomingCallRingtone(uiSettings.value?.incoming_call_ringtone)
  );
  const ringtoneEnabled = computed(
    () =>
      sourceId !== 'voice' ||
      uiSettings.value?.voice_call_ringtone_enabled !== false
  );

  watch(
    [isActive, selectedTone, ringtoneEnabled],
    ([active, tone, enabled]) => {
      IncomingCallRingtone.setSourceState(sourceId, {
        active: active && enabled,
        tone,
      });
    },
    { immediate: true }
  );

  onUnmounted(() => {
    IncomingCallRingtone.removeSource(sourceId);
  });
};
