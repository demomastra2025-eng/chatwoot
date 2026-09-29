import { computed, onUnmounted, watch } from 'vue';

import { useUISettings } from 'dashboard/composables/useUISettings';
import IncomingCallRingtone from 'dashboard/helper/AudioAlerts/IncomingCallRingtone';
import { resolveIncomingCallRingtone } from 'dashboard/helper/AudioAlerts/ringtone';

// The component that last reported each source. When the call cards move
// (the standalone cards give way to the phone widget's call list), the new
// list reports before the old one unmounts; the old one must not silence it.
const sourceOwners = new Map();

export const useIncomingCallRingtone = (sourceId, isActive) => {
  const owner = Symbol(sourceId);
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
      sourceOwners.set(sourceId, owner);
      IncomingCallRingtone.setSourceState(sourceId, {
        active: active && enabled,
        tone,
      });
    },
    { immediate: true }
  );

  onUnmounted(() => {
    if (sourceOwners.get(sourceId) !== owner) return;
    sourceOwners.delete(sourceId);
    IncomingCallRingtone.removeSource(sourceId);
  });
};
