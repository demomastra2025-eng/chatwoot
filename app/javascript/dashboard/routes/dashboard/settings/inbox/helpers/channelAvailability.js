// Which channels of the catalog a clinic may connect. The list comes from the
// server (`available_channels` of the account payload, built by
// Accounts::AvailableChannels): the platform switch, the clinic's own exception
// and the clinic's feature flag are already applied there, so a channel that is
// not in the list is hidden, never greyed out.
//
// One tile of the channel list can stand for several catalog channels: WhatsApp
// is the Cloud API, Twilio and WhatsApp Web, Telegram is a bot and a personal
// account. The tile is shown while at least one of its ways is available.
export const CHANNEL_TILES = {
  whatsapp: ['whatsapp_cloud', 'whatsapp_twilio', 'whatsapp_web'],
  telegram: ['telegram_bot', 'telegram_personal'],
};

// An account payload without the list (a copy cached before the list existed)
// offers everything, as it did before.
export const isChannelAvailable = (availableChannels, key) =>
  !Array.isArray(availableChannels) || availableChannels.includes(key);

export const isTileAvailable = (availableChannels, tileKey) =>
  (CHANNEL_TILES[tileKey] || [tileKey]).some(key =>
    isChannelAvailable(availableChannels, key)
  );
