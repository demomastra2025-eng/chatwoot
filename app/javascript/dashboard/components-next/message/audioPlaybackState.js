import { computed, reactive, unref } from 'vue';

const playbackStateByAttachmentId = reactive({});

const defaultPlaybackState = Object.freeze({
  timeLabel: '',
  isPlaying: false,
});

export const setAudioPlaybackState = (attachmentId, nextState) => {
  if (!attachmentId) return;

  playbackStateByAttachmentId[attachmentId] = {
    ...(playbackStateByAttachmentId[attachmentId] || {}),
    ...nextState,
  };
};

export const clearAudioPlaybackState = attachmentId => {
  if (!attachmentId || !playbackStateByAttachmentId[attachmentId]) return;

  delete playbackStateByAttachmentId[attachmentId];
};

export const useAudioPlaybackState = attachmentId => {
  return computed(() => {
    const resolvedAttachmentId = unref(attachmentId);

    if (!resolvedAttachmentId) {
      return defaultPlaybackState;
    }

    return (
      playbackStateByAttachmentId[resolvedAttachmentId] || defaultPlaybackState
    );
  });
};
