# frozen_string_literal: true

# The catalog of every channel a clinic can connect in the operator app.
#
# Each entry has its own platform-level switch (super admin «Каналы», InstallationConfig CHANNEL_VISIBILITY) and can be
# opened or closed for one clinic (account.custom_attributes['channel_overrides']). The operator app and the server
# guards read the result from Accounts::AvailableChannels.
#
# An entry is one *creation path*, not one tile of the channel list: WhatsApp is three entries (Cloud API, Twilio,
# WhatsApp Web) and Telegram is two (bot, personal account), because the operator picks them as separate choices and
# they create different channel records. Providers that live inside one choice (Google / Microsoft / IMAP for e-mail,
# Twilio / Bandwidth for SMS) share one entry.
#
#   Channels::Catalog.keys                         # => ["website", "facebook", ...]
#   Channels::Catalog.find('api').default          # => "hidden"
#   Channels::Catalog.key_for_create('telegram')   # => "telegram_bot"
class Channels::Catalog
  SHOWN = 'shown'
  HIDDEN = 'hidden'
  STATES = [SHOWN, HIDDEN].freeze

  # key         : the identifier used everywhere (platform setting, override, available_channels, API errors)
  # tile        : the tile of the operator app channel list the choice lives under (ChannelList.vue)
  # flag        : the account feature flag that must also be on (nil = no flag)
  # default     : visibility while the platform has no setting of its own
  # inbox_types : Inbox#channel_type values of the channel records it creates
  # creation    : every server-side path that creates it; each one is guarded (see Accounts::AvailableChannels)
  Entry = Struct.new(:key, :tile, :flag, :default, :inbox_types, :creation, keyword_init: true) do
    def name(locale: I18n.locale)
      I18n.t("super_admin.channels.names.#{key}", locale: locale, default: key)
    end

    def shown_by_default?
      default == SHOWN
    end
  end

  ENTRIES = [
    Entry.new(
      key: 'website', tile: 'website', flag: 'channel_website', default: SHOWN, inbox_types: %w[Channel::WebWidget],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=web_widget)']
    ),
    Entry.new(
      key: 'facebook', tile: 'facebook', flag: 'channel_facebook', default: SHOWN, inbox_types: %w[Channel::FacebookPage],
      creation: ['GET /api/v1/accounts/:account_id/callbacks/facebook_pages', 'POST /api/v1/accounts/:account_id/callbacks/register_facebook_page']
    ),
    Entry.new(
      key: 'instagram', tile: 'instagram', flag: 'channel_instagram', default: SHOWN, inbox_types: %w[Channel::Instagram],
      creation: ['POST /api/v1/accounts/:account_id/instagram/authorization (without inbox_id)', 'GET /instagram/callback (new account)']
    ),
    Entry.new(
      key: 'whatsapp_cloud', tile: 'whatsapp', flag: nil, default: SHOWN, inbox_types: %w[Channel::Whatsapp],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=whatsapp, Cloud API and 360dialog)',
                 'POST /api/v1/accounts/:account_id/whatsapp/authorization (embedded signup, without inbox_id)']
    ),
    Entry.new(
      key: 'whatsapp_twilio', tile: 'whatsapp', flag: nil, default: SHOWN, inbox_types: %w[Channel::TwilioSms],
      creation: ['POST /api/v1/accounts/:account_id/channels/twilio_channel (medium=whatsapp)']
    ),
    Entry.new(
      key: 'whatsapp_web', tile: 'whatsapp', flag: nil, default: SHOWN, inbox_types: %w[Channel::WhatsappWeb],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=whatsapp_web)']
    ),
    Entry.new(
      key: 'telegram_bot', tile: 'telegram', flag: nil, default: SHOWN, inbox_types: %w[Channel::Telegram],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=telegram)']
    ),
    Entry.new(
      key: 'telegram_personal', tile: 'telegram', flag: nil, default: SHOWN, inbox_types: %w[Channel::TelegramPersonal],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=telegram_personal)']
    ),
    Entry.new(
      key: 'email', tile: 'email', flag: 'channel_email', default: SHOWN, inbox_types: %w[Channel::Email],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=email)',
                 'GET /google/callback (new mailbox)', 'GET /microsoft/callback (new mailbox)']
    ),
    Entry.new(
      key: 'voice', tile: 'voice', flag: 'channel_voice', default: SHOWN, inbox_types: %w[Channel::Voice],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=voice)',
                 'POST /api/v1/accounts/:account_id/telephony/virtual_pbx_channels']
    ),
    Entry.new(
      key: 'tiktok', tile: 'tiktok', flag: 'channel_tiktok', default: HIDDEN, inbox_types: %w[Channel::Tiktok],
      creation: ['GET /tiktok/callback (new account)']
    ),
    Entry.new(
      key: 'twitter', tile: 'twitter', flag: 'channel_twitter', default: HIDDEN, inbox_types: %w[Channel::TwitterProfile],
      creation: ['POST /api/v1/accounts/:account_id/twitter/authorization', 'GET /twitter/callback']
    ),
    Entry.new(
      key: 'sms', tile: 'sms', flag: nil, default: HIDDEN, inbox_types: %w[Channel::Sms Channel::TwilioSms],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=sms, Bandwidth)',
                 'POST /api/v1/accounts/:account_id/channels/twilio_channel (medium=sms)']
    ),
    Entry.new(
      key: 'api', tile: 'api', flag: nil, default: HIDDEN, inbox_types: %w[Channel::Api],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=api)']
    ),
    Entry.new(
      key: 'line', tile: 'line', flag: nil, default: HIDDEN, inbox_types: %w[Channel::Line],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=line)']
    ),
    Entry.new(
      key: 'weixin', tile: 'weixin', flag: nil, default: HIDDEN, inbox_types: %w[Channel::Weixin],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=weixin)']
    ),
    Entry.new(
      key: 'vk_community', tile: 'vk_community', flag: nil, default: HIDDEN, inbox_types: %w[Channel::VkCommunity],
      creation: ['POST /api/v1/accounts/:account_id/inboxes (channel[type]=vk_community)']
    )
  ].freeze

  # `channel[type]` of POST /inboxes -> catalog key
  CREATE_TYPES = {
    'web_widget' => 'website',
    'whatsapp' => 'whatsapp_cloud',
    'whatsapp_web' => 'whatsapp_web',
    'telegram' => 'telegram_bot',
    'telegram_personal' => 'telegram_personal',
    'email' => 'email',
    'voice' => 'voice',
    'sms' => 'sms',
    'api' => 'api',
    'line' => 'line',
    'weixin' => 'weixin',
    'vk_community' => 'vk_community'
  }.freeze

  # Inbox#channel_type -> catalog key. Channel::TwilioSms is two entries, told apart by its medium.
  INBOX_TYPES = ENTRIES.each_with_object({}) do |entry, types|
    entry.inbox_types.each { |type| types[type] ||= entry.key unless type == 'Channel::TwilioSms' }
  end.freeze

  TWILIO_MEDIUM_KEYS = { 'whatsapp' => 'whatsapp_twilio', 'sms' => 'sms' }.freeze

  BY_KEY = ENTRIES.index_by(&:key).freeze

  class << self
    def entries
      ENTRIES
    end

    def keys
      BY_KEY.keys
    end

    def key?(key)
      BY_KEY.key?(key.to_s)
    end

    def find(key)
      BY_KEY[key.to_s]
    end

    def fetch(key)
      BY_KEY.fetch(key.to_s) { raise ArgumentError, "Unknown channel: #{key}" }
    end

    def name(key)
      find(key)&.name || key.to_s
    end

    # Visibility while the platform has no setting of its own: 'shown' or 'hidden'
    def default_state(key)
      fetch(key).default
    end

    def feature_flag(key)
      find(key)&.flag
    end

    # The catalog key for `channel[type]` of the inbox creation endpoint, nil for a type the endpoint does not know
    def key_for_create(type)
      CREATE_TYPES[type.to_s]
    end

    # The catalog key for the medium of a Twilio channel (sms / whatsapp)
    def key_for_twilio_medium(medium)
      TWILIO_MEDIUM_KEYS.fetch(medium.to_s, 'sms')
    end

    # The catalog key of an existing channel record. `medium` is only read for Channel::TwilioSms.
    def key_for_inbox_type(channel_type, medium: nil)
      return key_for_twilio_medium(medium) if channel_type.to_s == 'Channel::TwilioSms'

      INBOX_TYPES[channel_type.to_s]
    end

    # The Russian line shown to a clinic that tries to connect a channel it does not have. Always Russian (the
    # product is Russian-only), whatever locale the request runs in.
    def unavailable_message(key)
      I18n.t('errors.channels.not_available', locale: :ru, channel: find(key)&.name(locale: :ru) || key.to_s)
    end
  end
end
