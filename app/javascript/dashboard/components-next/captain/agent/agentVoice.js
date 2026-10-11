// An agent gets the «Голос» tab only when a voice channel answers with it.
// `config.voice_settings` is always filled in by the server, so it cannot be
// used as the signal: the binding of a Channel::Voice inbox is the only one.
export const VOICE_CHANNEL_TYPE = 'Channel::Voice';

export const isVoiceChannel = inbox =>
  inbox?.channel_type === VOICE_CHANNEL_TYPE;

export const voiceInboxesForAgent = (assistant, inboxes = []) => {
  const assistantId = Number(assistant?.id);
  if (!assistantId || !Array.isArray(inboxes)) return [];

  return inboxes.filter(
    inbox =>
      isVoiceChannel(inbox) &&
      Number(inbox?.captain_assistant?.id) === assistantId
  );
};

export const isVoiceAgent = (assistant, inboxes = []) =>
  voiceInboxesForAgent(assistant, inboxes).length > 0;
