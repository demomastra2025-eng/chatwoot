class Campaigns::ChannelCapabilities
  READY_CHANNEL_TYPES = %w[
    Channel::Sms
    Channel::TwilioSms
    Channel::Whatsapp
    Channel::Email
    Channel::WhatsappWeb
    Channel::Telegram
    Channel::TelegramPersonal
    Channel::VkCommunity
    Channel::Line
    Channel::FacebookPage
    Channel::Instagram
    Channel::Tiktok
    Channel::TwitterProfile
  ].freeze

  def self.for(inbox:)
    new(inbox: inbox).as_json
  end

  def initialize(inbox:)
    @inbox = inbox
  end

  def as_json
    base_payload.merge(channel_payload)
  end

  private

  attr_reader :inbox

  def base_payload
    {
      inbox_id: inbox.id,
      inbox_type: inbox.inbox_type,
      channel_type: inbox.display_channel_type,
      campaign_surface: 'outbound_audience',
      supports_outbound_campaigns: false,
      implemented_in_current_campaigns: READY_CHANNEL_TYPES.include?(inbox.channel_type),
      delivery_readiness: 'unsupported',
      planned_rollout_tier: nil,
      supports_first_contact: false,
      requires_existing_target: false,
      requires_open_reply_window: false,
      requires_template_for_outside_window: false,
      supports_plain_text: true,
      supports_subject: false,
      supports_html: false,
      supports_media: false,
      supports_buttons: false,
      notes: []
    }
  end

  def channel_payload
    case inbox.channel_type
    when 'Channel::Sms'
      {
        supports_outbound_campaigns: true,
        delivery_readiness: 'ready',
        planned_rollout_tier: 1,
        supports_first_contact: true
      }
    when 'Channel::TwilioSms'
      twilio_payload
    when 'Channel::Whatsapp'
      whatsapp_payload
    when 'Channel::Email'
      {
        supports_outbound_campaigns: true,
        delivery_readiness: 'ready',
        planned_rollout_tier: 1,
        supports_first_contact: true,
        supports_subject: true,
        supports_html: true,
        notes: [
          'Campaign title is used as the email subject.',
          'Message content is rendered into the email body automatically.'
        ]
      }
    when 'Channel::WhatsappWeb'
      {
        supports_outbound_campaigns: true,
        delivery_readiness: 'ready',
        planned_rollout_tier: 1,
        supports_first_contact: true,
        supports_media: true
      }
    when 'Channel::TelegramPersonal'
      {
        supports_outbound_campaigns: true,
        delivery_readiness: 'ready',
        planned_rollout_tier: 1,
        requires_existing_target: true,
        notes: ['Requires a stored Telegram user target before outbound delivery can start.']
      }
    when 'Channel::VkCommunity'
      {
        supports_outbound_campaigns: true,
        delivery_readiness: 'ready',
        planned_rollout_tier: 1,
        requires_existing_target: true,
        supports_media: true,
        notes: ['Requires an existing VK peer target before outbound delivery can start.']
      }
    when 'Channel::Line'
      {
        supports_outbound_campaigns: true,
        implemented_in_current_campaigns: true,
        delivery_readiness: 'ready',
        planned_rollout_tier: 1,
        requires_existing_target: true,
        supports_media: true,
        supports_buttons: true,
        notes: ['Requires an existing LINE user target before outbound delivery can start.']
      }
    when 'Channel::FacebookPage'
      {
        supports_outbound_campaigns: true,
        implemented_in_current_campaigns: true,
        delivery_readiness: 'ready',
        planned_rollout_tier: 2,
        requires_existing_target: true,
        requires_open_reply_window: true,
        supports_media: true,
        supports_buttons: true,
        notes: ['Requires an active Messenger reply window before outbound delivery can start.']
      }
    when 'Channel::Instagram'
      {
        supports_outbound_campaigns: true,
        implemented_in_current_campaigns: true,
        delivery_readiness: 'ready',
        planned_rollout_tier: 2,
        requires_existing_target: true,
        requires_open_reply_window: true,
        supports_media: true,
        notes: ['Requires an active Instagram reply window before outbound delivery can start.']
      }
    when 'Channel::Telegram'
      {
        supports_outbound_campaigns: true,
        implemented_in_current_campaigns: true,
        delivery_readiness: 'ready',
        planned_rollout_tier: 2,
        requires_existing_target: true,
        supports_media: true,
        supports_buttons: true,
        notes: ['Uses the existing private Telegram chat target for outbound delivery. Group conversations are not part of outbound campaigns.']
      }
    when 'Channel::Tiktok'
      {
        supports_outbound_campaigns: true,
        implemented_in_current_campaigns: true,
        delivery_readiness: 'ready',
        planned_rollout_tier: 3,
        requires_existing_target: true,
        requires_open_reply_window: true,
        supports_media: true,
        notes: ['Requires an existing TikTok conversation target and an active 48-hour reply window.']
      }
    when 'Channel::TwitterProfile'
      {
        supports_outbound_campaigns: true,
        implemented_in_current_campaigns: true,
        delivery_readiness: 'ready',
        planned_rollout_tier: 3,
        requires_existing_target: true,
        notes: ['Outbound campaigns use direct messages only and require an existing Twitter DM thread. Tweet reply conversations stay outside this surface.']
      }
    when 'Channel::WebWidget'
      {
        supports_outbound_campaigns: false,
        implemented_in_current_campaigns: true,
        campaign_surface: 'website_trigger',
        delivery_readiness: 'separate_surface',
        notes: ['Website campaigns stay on the separate trigger-based surface and are not part of outbound audience campaigns.']
      }
    when 'Channel::Api'
      {
        supports_outbound_campaigns: false,
        implemented_in_current_campaigns: false,
        delivery_readiness: 'unsupported',
        notes: ['API inboxes are not treated as a direct customer delivery transport for outbound campaigns.']
      }
    else
      {}
    end
  end

  def twilio_payload
    return twilio_sms_payload unless inbox.channel.medium == 'whatsapp'

    {
      supports_outbound_campaigns: true,
      delivery_readiness: 'ready',
      planned_rollout_tier: 1,
      supports_first_contact: true,
      supports_media: true
    }
  end

  def twilio_sms_payload
    {
      supports_outbound_campaigns: true,
      delivery_readiness: 'ready',
      planned_rollout_tier: 1,
      supports_first_contact: true,
      supports_media: true
    }
  end

  def whatsapp_payload
    return whatsapp_feature_disabled_payload unless inbox.account.feature_enabled?(:whatsapp_campaign)

    {
      supports_outbound_campaigns: true,
      delivery_readiness: 'ready',
      planned_rollout_tier: 1,
      supports_first_contact: true,
      requires_template_for_outside_window: true,
      supports_media: true,
      notes: ['Requires template params when the contact is outside the active reply window.']
    }
  end

  def whatsapp_feature_disabled_payload
    {
      supports_outbound_campaigns: false,
      delivery_readiness: 'unsupported',
      planned_rollout_tier: 1,
      notes: ['WhatsApp campaigns feature is not enabled for this account.']
    }
  end
end
