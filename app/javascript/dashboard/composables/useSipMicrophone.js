import { computed, onMounted, onUnmounted, shallowRef, watch } from 'vue';

import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';

const unavailable = { available: false, muted: false };

export const useSipMicrophone = activeCall => {
  const callScope = computed(() => {
    const call = activeCall.value;
    if (!call?.isActive) return null;
    return {
      provider: call.provider,
      inboxId: call.inboxId,
      sipProfileId: call.sipProfileId,
      sessionKey: call.janusSessionKey || call.sessionKey,
      callRef: call.callRef || call.callSid,
      janusCallRef: call.janusCallRef,
    };
  });
  const microphoneState = shallowRef(unavailable);
  const refresh = () => {
    microphoneState.value = callScope.value
      ? WebphoneClient.microphoneState(callScope.value)
      : unavailable;
  };
  watch(callScope, refresh, { immediate: true });
  const microphoneAvailable = computed(() => microphoneState.value.available);
  const microphoneMuted = computed(() => microphoneState.value.muted);
  const toggleMicrophone = () => {
    if (!microphoneAvailable.value) return false;
    const toggled = WebphoneClient.toggleMicrophone(callScope.value);
    refresh();
    return toggled;
  };

  onMounted(() => {
    ['call:connected', 'call:disconnected', 'call:microphone-state'].forEach(
      eventName => WebphoneClient.addEventListener(eventName, refresh)
    );
  });
  onUnmounted(() => {
    ['call:connected', 'call:disconnected', 'call:microphone-state'].forEach(
      eventName => WebphoneClient.removeEventListener(eventName, refresh)
    );
  });

  return { microphoneAvailable, microphoneMuted, toggleMicrophone };
};
