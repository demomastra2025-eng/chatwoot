import { computed, reactive, toRaw, unref } from 'vue';

// attachmentId -> { [ownerId]: { timeLabel, isPlaying } }
//
// The same attachment can be rendered by several audio chips at once (e.g. a
// search result and the live conversation). Each chip keeps its own entry so
// the chips never overwrite each other.
const playbackStateByAttachmentId = reactive({});

const DEFAULT_OWNER_ID = 'default';

const defaultPlaybackState = Object.freeze({
  timeLabel: '',
  isPlaying: false,
});

// Chips publish their state from a watchEffect. Reads here go through the raw
// store so a publishing effect never subscribes to the store it writes to;
// otherwise two chips sharing an attachment id would re-trigger each other
// forever ("Maximum recursive updates exceeded" in development, a frozen tab
// in production builds, where Vue does not guard against the loop).
export const setAudioPlaybackState = (
  attachmentId,
  nextState,
  ownerId = DEFAULT_OWNER_ID
) => {
  if (!attachmentId) return;

  const rawStore = toRaw(playbackStateByAttachmentId);
  const currentOwners = rawStore[attachmentId];
  const currentState = currentOwners?.[ownerId];
  const mergedState = { ...(currentState || {}), ...nextState };

  const isUnchanged =
    currentState &&
    Object.keys(mergedState).every(
      key => currentState[key] === mergedState[key]
    );
  if (isUnchanged) return;

  if (!currentOwners) {
    playbackStateByAttachmentId[attachmentId] = { [ownerId]: mergedState };
    return;
  }

  // reactive(raw) hands back the existing proxy without tracking a read.
  reactive(currentOwners)[ownerId] = mergedState;
};

export const clearAudioPlaybackState = (
  attachmentId,
  ownerId = DEFAULT_OWNER_ID
) => {
  const currentOwners = toRaw(playbackStateByAttachmentId)[attachmentId];
  if (!attachmentId || !currentOwners?.[ownerId]) return;

  if (Object.keys(currentOwners).length === 1) {
    delete playbackStateByAttachmentId[attachmentId];
    return;
  }

  delete reactive(currentOwners)[ownerId];
};

export const useAudioPlaybackState = attachmentId => {
  return computed(() => {
    const resolvedAttachmentId = unref(attachmentId);

    if (!resolvedAttachmentId) {
      return defaultPlaybackState;
    }

    const owners = Object.values(
      playbackStateByAttachmentId[resolvedAttachmentId] || {}
    );

    return (
      owners.find(state => state.isPlaying) || owners[0] || defaultPlaybackState
    );
  });
};
