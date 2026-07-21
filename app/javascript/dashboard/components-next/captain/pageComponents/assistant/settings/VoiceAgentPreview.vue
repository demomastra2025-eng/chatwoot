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
  outputLevel,
  provider,
  start,
  status,
  stop,
} = useVoiceAgentPreview(assistantId);

const duration = computed(() => {
  const minutes = Math.floor(elapsedSeconds.value / 60);
  const seconds = elapsedSeconds.value % 60;
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
});

const statusLabel = computed(() => {
  if (status.value === 'connecting')
    return t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.STATUS.CONNECTING');
  if (status.value === 'listening')
    return t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.STATUS.LISTENING');
  if (status.value === 'speaking')
    return t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.STATUS.SPEAKING');
  if (status.value === 'error')
    return t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.STATUS.ERROR');
  return t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.STATUS.IDLE');
});
const errorLabel = computed(() => {
  if (errorCode.value === 'microphone')
    return t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.ERROR.MICROPHONE');
  if (errorCode.value === 'expired')
    return t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.ERROR.EXPIRED');
  if (errorCode.value === 'connection')
    return t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.ERROR.CONNECTION');
  if (errorCode.value === 'unavailable')
    return t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.ERROR.UNAVAILABLE');
  return '';
});
const displayProvider = computed(
  () => provider.value || props.configuredProvider
);
const level = computed(() => Math.max(inputLevel.value, outputLevel.value));
const bars = Array.from({ length: 19 }, (_, index) => index);
const barHeight = index => {
  const distance = Math.abs(index - 9) / 9;
  const wave = 0.3 + (1 - distance) * 0.7;
  return `${Math.max(14, Math.round(14 + level.value * wave * 34))}px`;
};
</script>

<template>
  <section
    class="overflow-hidden rounded-2xl border border-n-weak bg-n-solid-1"
    data-test-id="voice-agent-preview"
  >
    <div
      class="flex flex-col gap-5 p-5 md:flex-row md:items-center md:justify-between md:p-6"
    >
      <div class="flex min-w-0 items-center gap-4">
        <div
          class="relative flex size-16 shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-violet-500 via-blue-500 to-cyan-400 shadow-lg shadow-blue-500/20"
          :class="{ 'animate-pulse': isActive }"
        >
          <div class="size-8 rounded-full bg-white/20 backdrop-blur-sm" />
          <span
            v-if="isActive"
            class="absolute inset-0 rounded-full border border-white/40"
          />
        </div>
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="text-base font-medium text-n-slate-12">
              {{ t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.TITLE') }}
            </h3>
            <span
              v-if="displayProvider"
              class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-xs text-n-slate-11"
            >
              {{ displayProvider }}
            </span>
          </div>
          <p class="mt-1 text-sm text-n-slate-11">
            {{ t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.DESCRIPTION') }}
          </p>
        </div>
      </div>

      <div class="flex shrink-0 items-center gap-3">
        <div v-if="isActive" class="min-w-20 text-right">
          <div class="font-mono text-sm text-n-slate-12">{{ duration }}</div>
          <div class="text-xs text-n-slate-10">{{ statusLabel }}</div>
        </div>
        <Button
          v-if="!isActive"
          icon="i-lucide-phone-call"
          :label="t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.START')"
          :is-loading="status === 'connecting'"
          @click="start"
        />
        <Button
          v-else
          color="ruby"
          icon="i-lucide-phone-off"
          :label="t('CAPTAIN.ASSISTANTS.SETTINGS.VOICE_PREVIEW.STOP')"
          @click="stop()"
        />
      </div>
    </div>

    <div
      v-if="isActive"
      class="flex h-20 items-center justify-center gap-1 border-t border-n-weak bg-n-alpha-1 px-5"
      aria-hidden="true"
    >
      <span
        v-for="index in bars"
        :key="index"
        class="w-1 rounded-full bg-blue-500 transition-[height] duration-75"
        :style="{ height: barHeight(index) }"
      />
    </div>

    <p
      v-if="status === 'error'"
      class="border-t border-n-weak bg-ruby-1 px-5 py-3 text-sm text-ruby-9"
      role="alert"
    >
      {{ errorLabel }}
    </p>
  </section>
</template>
