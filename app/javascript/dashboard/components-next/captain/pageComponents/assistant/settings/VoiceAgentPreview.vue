<script setup>
import { computed, toRef } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import { useVoiceAgentPreview } from 'dashboard/composables/useVoiceAgentPreview';

const props = defineProps({
  assistantId: {
    type: [Number, String],
    required: true,
  },
  configuredProvider: {
    type: String,
    default: '',
  },
});

const { t } = useI18n();
const assistantId = toRef(props, 'assistantId');
const {
  elapsedSeconds,
  errorCode,
  inputLevel,
  isActive,
  isConnected,
  isMuted,
  outputLevel,
  provider,
  start,
  status,
  stop,
  toggleMute,
} = useVoiceAgentPreview(assistantId);

const duration = computed(() => {
  const minutes = Math.floor(elapsedSeconds.value / 60);
  const seconds = elapsedSeconds.value % 60;
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
});

const statusLabel = computed(() => {
  if (status.value === 'connecting')
    return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.STATUS.CONNECTING');
  if (status.value === 'listening')
    return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.STATUS.LISTENING');
  if (status.value === 'speaking')
    return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.STATUS.SPEAKING');
  if (status.value === 'error')
    return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.STATUS.ERROR');
  return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.STATUS.IDLE');
});
const errorLabel = computed(() => {
  if (errorCode.value === 'microphone')
    return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.ERROR.MICROPHONE');
  if (errorCode.value === 'expired')
    return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.ERROR.EXPIRED');
  if (errorCode.value === 'connection')
    return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.ERROR.CONNECTION');
  if (errorCode.value === 'unavailable')
    return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.ERROR.UNAVAILABLE');
  if (errorCode.value === 'capacity')
    return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.ERROR.CAPACITY');
  if (errorCode.value === 'origin')
    return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.ERROR.ORIGIN');
  if (errorCode.value === 'protocol')
    return t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.ERROR.PROTOCOL');
  return '';
});
const PROVIDER_LABELS = Object.freeze({
  'gemini-live': 'Gemini Live',
  'openai-realtime': 'OpenAI Realtime',
  elevenlabs: 'ElevenLabs + OpenRouter',
  cartesia: 'Cartesia + OpenRouter',
});
const displayProvider = computed(() => {
  const value = provider.value || props.configuredProvider;
  return PROVIDER_LABELS[value] || value;
});
const level = computed(() =>
  status.value === 'speaking' ? outputLevel.value : inputLevel.value
);
const muteLabel = computed(() =>
  isMuted.value
    ? t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.UNMUTE')
    : t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.MUTE')
);
const stopLabel = computed(() =>
  status.value === 'connecting'
    ? t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.CANCEL')
    : t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.STOP')
);
const statusClasses = computed(() => {
  const classes = {
    connecting: 'border-n-violet-5 bg-n-violet-2 text-n-violet-11',
    listening: 'border-n-teal-5 bg-n-teal-2 text-n-teal-11',
    speaking: 'border-n-blue-5 bg-n-blue-2 text-n-blue-11',
    error: 'border-n-ruby-5 bg-n-ruby-2 text-n-ruby-11',
  };
  return classes[status.value] || 'border-n-weak bg-n-solid-1 text-n-slate-11';
});
const statusDotClasses = computed(() => {
  const classes = {
    connecting: 'bg-n-violet-9 animate-pulse',
    listening: 'bg-n-teal-9',
    speaking: 'bg-n-blue-9 animate-pulse',
    error: 'bg-n-ruby-9',
  };
  return classes[status.value] || 'bg-n-slate-7';
});
const bars = Array.from({ length: 17 }, (_, index) => index);
const barHeight = index => {
  if (status.value === 'connecting') {
    return `${14 + ((index + 2) % 5) * 4}px`;
  }

  const center = (bars.length - 1) / 2;
  const distance = Math.abs(index - center) / center;
  const wave = 0.3 + (1 - distance) * 0.7;
  return `${Math.max(14, Math.round(14 + level.value * wave * 34))}px`;
};
</script>

<template>
  <section
    class="relative overflow-hidden rounded-2xl border border-n-weak bg-n-solid-1"
    data-test-id="voice-agent-preview"
  >
    <div
      class="pointer-events-none absolute inset-0 bg-gradient-to-br from-n-violet-2 via-transparent to-n-blue-2 opacity-70"
    />
    <div
      class="relative flex flex-col items-center gap-6 p-5 text-center md:p-8"
    >
      <div
        class="flex w-full min-w-0 flex-col items-start justify-between gap-3 text-left sm:flex-row sm:gap-4"
      >
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="text-base font-medium text-n-slate-12">
              {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.TITLE') }}
            </h3>
            <span
              v-if="displayProvider"
              class="rounded-full border border-n-weak bg-n-solid-1 px-2 py-0.5 text-xs text-n-slate-11"
            >
              {{ displayProvider }}
            </span>
          </div>
          <p class="mt-1 max-w-2xl text-sm text-n-slate-11">
            {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.DESCRIPTION') }}
          </p>
        </div>
        <div
          class="flex shrink-0 items-center gap-2 rounded-full border border-n-weak bg-n-solid-1 px-3 py-1.5 text-xs font-medium text-n-slate-11"
          :class="statusClasses"
          role="status"
          aria-live="polite"
        >
          <span class="size-2 rounded-full" :class="statusDotClasses" />
          {{ statusLabel }}
        </div>
      </div>

      <div
        class="relative flex h-40 w-full items-center justify-center"
        :data-state="status"
      >
        <div
          v-if="isActive"
          class="absolute size-36 rounded-full bg-n-violet-5/40 blur-2xl transition-transform duration-150"
          :style="{ transform: `scale(${1 + level * 0.35})` }"
        />
        <div
          v-if="isActive"
          class="absolute size-32 rounded-full border border-n-violet-6/50 transition-transform duration-300"
          :class="{ 'animate-ping': status === 'connecting' }"
        />
        <div
          class="relative flex size-28 shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-violet-500 via-blue-500 to-cyan-400 shadow-xl shadow-blue-500/25 transition-transform duration-100"
          :style="{ transform: `scale(${1 + level * 0.08})` }"
        >
          <div class="size-14 rounded-full bg-white/20 backdrop-blur-md" />
          <i class="i-lucide-audio-waveform absolute size-7 text-white" />
        </div>
      </div>

      <div v-if="isActive" class="w-full max-w-md">
        <div
          class="flex h-14 items-center justify-center gap-1 rounded-xl border border-n-weak bg-n-solid-1/80 px-5"
          aria-hidden="true"
        >
          <span
            v-for="index in bars"
            :key="index"
            class="w-1 rounded-full transition-[height,background-color] duration-75"
            :class="status === 'speaking' ? 'bg-n-blue-9' : 'bg-n-violet-9'"
            :style="{ height: barHeight(index) }"
          />
        </div>
        <div
          v-if="isConnected"
          class="mt-3 font-mono text-sm tabular-nums text-n-slate-12"
        >
          {{ duration }}
        </div>
      </div>

      <div class="flex shrink-0 items-center justify-center gap-3">
        <Button
          v-if="!isActive"
          icon="i-lucide-phone-call"
          :label="t('CAPTAIN.ASSISTANTS.FORM.VOICE_PREVIEW.START')"
          :is-loading="status === 'connecting'"
          @click="start"
        />
        <button
          v-if="isActive"
          type="button"
          class="flex size-11 items-center justify-center rounded-full border border-n-weak bg-n-solid-1 text-n-slate-12 transition hover:bg-n-alpha-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-violet-9"
          :aria-label="muteLabel"
          :aria-pressed="isMuted"
          :title="muteLabel"
          :disabled="!isConnected"
          :class="{ 'cursor-not-allowed opacity-50': !isConnected }"
          @click="toggleMute"
        >
          <i
            :class="isMuted ? 'i-lucide-mic-off' : 'i-lucide-mic'"
            class="size-5"
          />
        </button>
        <Button
          v-if="isActive"
          color="ruby"
          icon="i-lucide-phone-off"
          :label="stopLabel"
          @click="stop()"
        />
      </div>
    </div>

    <p
      v-if="status === 'error'"
      class="relative border-t border-n-weak bg-ruby-1 px-5 py-3 text-sm text-ruby-9"
      role="alert"
    >
      {{ errorLabel }}
    </p>
  </section>
</template>
