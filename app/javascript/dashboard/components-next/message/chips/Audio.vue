<script setup>
import {
  computed,
  onMounted,
  onUnmounted,
  useTemplateRef,
  ref,
  watch,
  watchEffect,
  getCurrentInstance,
  nextTick,
} from 'vue';
import { useResizeObserver } from '@vueuse/core';
import WaveSurfer from 'wavesurfer.js';
import Icon from 'next/icon/Icon.vue';
import { timeStampAppendedURL } from 'dashboard/helper/URLHelper';
import { downloadFile } from '@chatwoot/utils';
import { useEmitter } from 'dashboard/composables/emitter';
import { emitter } from 'shared/helpers/mitt';
import {
  clearAudioPlaybackState,
  setAudioPlaybackState,
} from '../audioPlaybackState';

const { attachment } = defineProps({
  attachment: {
    type: Object,
    required: true,
  },
  showTranscribedText: {
    type: Boolean,
    default: true,
  },
});

defineOptions({
  inheritAttrs: false,
});

const waveformContainer = useTemplateRef('waveformContainer');
const audioElement = useTemplateRef('audioElement');

const MIN_WAVEFORM_CONTAINER_WIDTH = 24;

const normalizeCurrentOriginMediaURL = dataUrl => {
  if (!dataUrl) return dataUrl;

  const fallbackOrigin =
    typeof window !== 'undefined' ? window.location.origin : 'http://localhost';
  const url = new URL(dataUrl, fallbackOrigin);

  if (typeof window === 'undefined') {
    return url.toString();
  }

  const isActiveStorageOrAudioPath =
    /^\/(rails\/active_storage\/|audio\/)/.test(url.pathname);

  if (isActiveStorageOrAudioPath && url.origin !== window.location.origin) {
    url.protocol = window.location.protocol;
    url.host = window.location.host;
  }

  return url.toString();
};

const normalizedAudioURL = computed(() => {
  return normalizeCurrentOriginMediaURL(attachment.dataUrl);
});

const timeStampURL = computed(() => {
  if (!normalizedAudioURL.value) return '';
  return timeStampAppendedURL(normalizedAudioURL.value);
});

const isPlaying = ref(false);
const isMuted = ref(false);
const isAudioReady = ref(false);
const currentTime = ref(0);
const duration = ref(0);
const playbackSpeed = ref(1);
const waveSurfer = ref(null);
const isFallbackMode = ref(false);
const waveformInitFrameId = ref(0);

const { uid } = getCurrentInstance();

const playbackSpeedLabel = computed(() => `${playbackSpeed.value}x`);

const destroyWaveform = () => {
  if (waveSurfer.value) {
    waveSurfer.value.destroy();
    waveSurfer.value = null;
  }
};

const clearPendingWaveformInit = () => {
  if (waveformInitFrameId.value) {
    cancelAnimationFrame(waveformInitFrameId.value);
    waveformInitFrameId.value = 0;
  }
};

const unloadNativeAudio = () => {
  const audio = audioElement.value;

  if (!audio) return;

  audio.pause();
  audio.removeAttribute('src');
  audio.load();
};

const resetPlayerState = (muted = false) => {
  currentTime.value = 0;
  duration.value = 0;
  isPlaying.value = false;
  isAudioReady.value = false;
  playbackSpeed.value = 1;
  isMuted.value = muted;
};

const loadNativeAudio = async () => {
  await nextTick();

  const audio = audioElement.value;
  if (!audio || !timeStampURL.value) return;

  audio.src = timeStampURL.value;
  audio.muted = isMuted.value;
  audio.playbackRate = playbackSpeed.value;
  audio.load();
};

const activateNativeFallback = async () => {
  if (isFallbackMode.value) return;

  const muted = isMuted.value;
  isFallbackMode.value = true;
  clearPendingWaveformInit();
  destroyWaveform();
  resetPlayerState(muted);
  await loadNativeAudio();
};

const onWaveformError = async () => {
  await activateNativeFallback();
};

const getContainerWidth = () => {
  return Math.floor(waveformContainer.value?.clientWidth || 0);
};

const canRenderWaveform = () => {
  return (
    !!waveformContainer.value &&
    !!timeStampURL.value &&
    getContainerWidth() >= MIN_WAVEFORM_CONTAINER_WIDTH
  );
};

const initWaveform = async () => {
  if (!canRenderWaveform() || isFallbackMode.value) return;

  const muted = isMuted.value;
  destroyWaveform();
  resetPlayerState(muted);

  waveSurfer.value = WaveSurfer.create({
    container: waveformContainer.value,
    waveColor: '#AEBACB',
    progressColor: '#1F93FF',
    cursorWidth: 0,
    height: 44,
    barWidth: 2,
    barGap: 1,
    barRadius: 2,
    normalize: true,
    interact: false,
    hideScrollbar: true,
  });

  waveSurfer.value.setMuted(muted);
  waveSurfer.value.setPlaybackRate(playbackSpeed.value);

  waveSurfer.value.on('ready', waveDuration => {
    duration.value = Number.isFinite(waveDuration)
      ? waveDuration
      : waveSurfer.value?.getDuration() || 0;
    currentTime.value = waveSurfer.value?.getCurrentTime() || 0;
    isAudioReady.value = true;
    isMuted.value = waveSurfer.value?.getMuted() || false;
  });

  waveSurfer.value.on('timeupdate', time => {
    currentTime.value = time || 0;
  });

  waveSurfer.value.on('play', () => {
    isPlaying.value = true;
  });

  waveSurfer.value.on('pause', () => {
    isPlaying.value = false;
  });

  waveSurfer.value.on('finish', () => {
    isPlaying.value = false;
    currentTime.value = 0;
    playbackSpeed.value = 1;
    waveSurfer.value?.setPlaybackRate(1);
    waveSurfer.value?.setTime(0);
  });

  waveSurfer.value.on('error', onWaveformError);

  try {
    await waveSurfer.value.load(timeStampURL.value);
  } catch {
    await onWaveformError();
  }
};

const scheduleWaveformInit = () => {
  if (waveSurfer.value || isFallbackMode.value || !canRenderWaveform()) return;

  clearPendingWaveformInit();
  waveformInitFrameId.value = requestAnimationFrame(() => {
    waveformInitFrameId.value = 0;
    initWaveform();
  });
};

watch(timeStampURL, () => {
  const muted = isMuted.value;
  isFallbackMode.value = false;
  clearPendingWaveformInit();
  destroyWaveform();
  unloadNativeAudio();
  resetPlayerState(muted);
  scheduleWaveformInit();
});

onMounted(() => {
  scheduleWaveformInit();
});

onUnmounted(() => {
  clearPendingWaveformInit();
  unloadNativeAudio();
  destroyWaveform();
  clearAudioPlaybackState(attachment.id);
});

useResizeObserver(waveformContainer, () => {
  scheduleWaveformInit();
});

useEmitter('pause_playing_audio', currentPlayingId => {
  if (currentPlayingId !== uid && isPlaying.value) {
    try {
      if (waveSurfer.value && !isFallbackMode.value) {
        waveSurfer.value.pause();
      } else {
        audioElement.value?.pause();
      }
    } catch {
      /* ignore pause errors */
    }
    isPlaying.value = false;
  }
});

const formatTime = time => {
  if (!time || Number.isNaN(time)) return '00:00';
  const minutes = Math.floor(time / 60);
  const seconds = Math.floor(time % 60);
  return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
};

const playbackTimeLabel = computed(() => {
  return `${formatTime(currentTime.value)} / ${formatTime(duration.value)}`;
});

const toggleMute = () => {
  if (waveSurfer.value && !isFallbackMode.value) {
    const nextMutedState = !waveSurfer.value.getMuted();
    waveSurfer.value.setMuted(nextMutedState);
    isMuted.value = nextMutedState;
    return;
  }

  const audio = audioElement.value;
  if (!audio) return;

  const nextMutedState = !audio.muted;
  audio.muted = nextMutedState;
  isMuted.value = nextMutedState;
};

const seek = event => {
  if (!duration.value) return;

  const nextTime = Number(event.target.value);

  if (waveSurfer.value && !isFallbackMode.value) {
    waveSurfer.value.setTime(nextTime);
    currentTime.value = nextTime;
    return;
  }

  const audio = audioElement.value;
  if (!audio) return;

  audio.currentTime = nextTime;
  currentTime.value = nextTime;
};

const playOrPause = async () => {
  if (!isAudioReady.value) return;

  emitter.emit('pause_playing_audio', uid);

  if (waveSurfer.value && !isFallbackMode.value) {
    try {
      await waveSurfer.value.playPause();
    } catch {
      await activateNativeFallback();
    }
    return;
  }

  const audio = audioElement.value;
  if (!audio) return;

  try {
    if (audio.paused) {
      await audio.play();
    } else {
      audio.pause();
    }
  } catch {
    isPlaying.value = false;
  }
};

const changePlaybackSpeed = () => {
  const speeds = [1, 1.5, 2];
  const currentIndex = speeds.indexOf(playbackSpeed.value);
  const nextIndex = (currentIndex + 1) % speeds.length;
  playbackSpeed.value = speeds[nextIndex];

  if (waveSurfer.value && !isFallbackMode.value) {
    waveSurfer.value.setPlaybackRate(playbackSpeed.value);
    return;
  }

  if (audioElement.value) {
    audioElement.value.playbackRate = playbackSpeed.value;
  }
};

const downloadAudio = () => {
  const { fileType, extension } = attachment;
  downloadFile({
    url: normalizedAudioURL.value,
    type: fileType,
    extension,
  });
};

const onNativeAudioLoadedMetadata = () => {
  if (!isFallbackMode.value || !audioElement.value) return;

  duration.value = Number.isFinite(audioElement.value.duration)
    ? audioElement.value.duration
    : 0;
  currentTime.value = audioElement.value.currentTime || 0;
  isAudioReady.value = true;
  isMuted.value = audioElement.value.muted;
};

const onNativeAudioTimeUpdate = () => {
  if (!isFallbackMode.value || !audioElement.value) return;

  currentTime.value = audioElement.value.currentTime || 0;
};

const onNativeAudioPlay = () => {
  if (!isFallbackMode.value) return;
  isPlaying.value = true;
};

const onNativeAudioPause = () => {
  if (!isFallbackMode.value) return;
  isPlaying.value = false;
};

const onNativeAudioEnded = () => {
  if (!isFallbackMode.value || !audioElement.value) return;

  isPlaying.value = false;
  currentTime.value = 0;
  playbackSpeed.value = 1;
  audioElement.value.playbackRate = 1;
};

const onNativeAudioError = () => {
  if (!isFallbackMode.value) return;
  resetPlayerState(isMuted.value);
};

watchEffect(() => {
  setAudioPlaybackState(attachment.id, {
    timeLabel: playbackTimeLabel.value,
    isPlaying: isPlaying.value,
  });
});
</script>

<template>
  <div
    v-bind="$attrs"
    class="w-[min(24rem,calc(100vw-6rem))] max-w-full gap-2 flex flex-col items-stretch"
  >
    <div class="flex gap-1.5 w-full flex-1 items-center justify-start">
      <button class="p-0 border-0 size-8" @click="playOrPause">
        <Icon
          v-if="isPlaying"
          class="size-8"
          icon="i-teenyicons-pause-small-solid"
        />
        <Icon v-else class="size-8" icon="i-teenyicons-play-small-solid" />
      </button>
      <div class="flex-1 min-w-0 relative">
        <div
          ref="waveformContainer"
          class="min-h-11 w-full overflow-hidden pointer-events-none"
        />
        <input
          type="range"
          min="0"
          :max="duration || 0.01"
          step="0.01"
          :value="currentTime"
          :disabled="!isAudioReady"
          class="absolute inset-0 opacity-0 cursor-pointer disabled:cursor-not-allowed"
          @input="seek"
        />
      </div>
      <button
        class="p-0 border-0 size-8 grid place-content-center"
        @click="toggleMute"
      >
        <Icon v-if="isMuted" class="size-4" icon="i-lucide-volume-off" />
        <Icon v-else class="size-4" icon="i-lucide-volume-2" />
      </button>
      <button
        v-if="isPlaying"
        class="border-0 w-10 h-6 grid place-content-center bg-n-alpha-2 hover:bg-alpha-3 rounded-2xl"
        @click="changePlaybackSpeed"
      >
        <span class="text-xs text-n-slate-11 font-medium">
          {{ playbackSpeedLabel }}
        </span>
      </button>
      <button
        v-else
        class="p-0 border-0 size-8 grid place-content-center"
        @click="downloadAudio"
      >
        <Icon class="size-4" icon="i-lucide-download" />
      </button>
    </div>
    <audio
      ref="audioElement"
      class="hidden"
      preload="metadata"
      @loadedmetadata="onNativeAudioLoadedMetadata"
      @timeupdate="onNativeAudioTimeUpdate"
      @play="onNativeAudioPlay"
      @pause="onNativeAudioPause"
      @ended="onNativeAudioEnded"
      @error="onNativeAudioError"
    />

    <div
      v-if="attachment.transcribedText && showTranscribedText"
      class="text-n-slate-12 p-3 text-sm bg-n-alpha-1 rounded-lg w-full break-words"
    >
      {{ attachment.transcribedText }}
    </div>
  </div>
</template>
