// An agent gets the «Голос» tab only when a voice channel answers with it.
// `config.voice_settings` is always filled in by the server, so it cannot be
// used as the signal: the voice numbers that name the agent
// (`assistant.voice_inbox_ids`) are the only one. A text channel names no agent.
export const VOICE_CHANNEL_TYPE = 'Channel::Voice';

export const isVoiceChannel = inbox =>
  inbox?.channel_type === VOICE_CHANNEL_TYPE;

export const voiceInboxesForAgent = (assistant, inboxes = []) => {
  const voiceIds = new Set((assistant?.voice_inbox_ids || []).map(Number));
  if (!voiceIds.size || !Array.isArray(inboxes)) return [];

  return inboxes.filter(
    inbox => isVoiceChannel(inbox) && voiceIds.has(Number(inbox?.id))
  );
};

export const isVoiceAgent = (assistant, inboxes = []) =>
  voiceInboxesForAgent(assistant, inboxes).length > 0;
