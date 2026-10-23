// Voice providers whose employees and extensions are managed in OneLink. The
// «Звонки и сотрудники» tab exists only for these.
export const VIRTUAL_PBX_PROVIDERS = [
  'asterisk_analog',
  'sipuni',
  'binotel',
  'beeline',
  'wazo',
];

export const VOICE_CHANNEL_TYPE = 'Channel::Voice';

export const isVirtualPbxVoiceInbox = inbox =>
  inbox?.channel_type === VOICE_CHANNEL_TYPE &&
  VIRTUAL_PBX_PROVIDERS.includes(inbox?.provider);
