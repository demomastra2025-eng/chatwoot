# == Schema Information
#
# Table name: channel_api
#
#  id                    :bigint           not null, primary key
#  additional_attributes :jsonb
#  hmac_mandatory        :boolean          default(FALSE)
#  hmac_token            :string
#  identifier            :string
#  secret                :string
#  webhook_url           :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :integer          not null
#
# Indexes
#
#  index_channel_api_on_hmac_token  (hmac_token) UNIQUE
#  index_channel_api_on_identifier  (identifier) UNIQUE
#

class Channel::Api < ApplicationRecord
  include Channelable

  WHATSAPP_WEB_PROVIDER = 'whatsapp_web'
  EVOLUTION_ATTRIBUTE_KEY = 'evolution'
  EVOLUTION_PROVIDER = 'evolution_api'
  STATUS_CREATING = 'creating'
  STATUS_WAITING_FOR_QR = 'waiting_for_qr'
  STATUS_QR_READY = 'qr_ready'
  STATUS_CONNECTED = 'connected'
  STATUS_FAILED = 'failed'

  self.table_name = 'channel_api'
  EDITABLE_ATTRS = [:webhook_url, :hmac_mandatory, { additional_attributes: {} }].freeze

  has_secure_token :identifier
  has_secure_token :hmac_token
  include WebhookSecretable
  before_validation :normalize_whatsapp_web_settings!
  validate :ensure_valid_agent_reply_time_window
  validate :ensure_whatsapp_web_number, if: :whatsapp_web_provider?
  validates :webhook_url, length: { maximum: Limits::URL_LENGTH_LIMIT }

  def name
    return 'WhatsApp Web' if whatsapp_web_provider?

    'API'
  end

  def provider
    additional_attributes&.dig('provider')
  end

  def whatsapp_web_provider?
    provider == WHATSAPP_WEB_PROVIDER
  end

  def evolution_attributes
    (additional_attributes || {})[EVOLUTION_ATTRIBUTE_KEY] || {}
  end

  def configured_number
    return unless whatsapp_web_provider?

    normalize_number(additional_attributes&.dig('number') || evolution_attributes['number'])
  end

  def generated_inbox_name
    return unless whatsapp_web_provider?

    [account_id, configured_number.presence || identifier].compact.join('_')
  end

  def generated_evolution_instance_name
    return unless whatsapp_web_provider?

    "onelink-waweb-#{generated_inbox_name}"
  end

  def default_webhook_url
    return if evolution_api_url.blank? || !whatsapp_web_provider?

    "#{evolution_api_url}/chatwoot/webhook/#{generated_evolution_instance_name}"
  end

  def update_evolution_attributes!(attributes)
    attrs = (additional_attributes || {}).deep_dup.deep_stringify_keys
    normalized_attributes = attributes.stringify_keys
    normalized_number = normalize_number(normalized_attributes['number'])

    attrs['provider'] = WHATSAPP_WEB_PROVIDER
    attrs['number'] = normalized_number if normalized_number.present?
    attrs[EVOLUTION_ATTRIBUTE_KEY] = evolution_attributes.merge(normalized_attributes)
    update!(additional_attributes: attrs)
  end

  private

  def ensure_valid_agent_reply_time_window
    return if additional_attributes.blank?
    return if additional_attributes['agent_reply_time_window'].blank?
    return if additional_attributes['agent_reply_time_window'].to_i.positive?

    errors.add(:agent_reply_time_window, 'agent_reply_time_window must be greater than 0')
  end

  def ensure_whatsapp_web_number
    errors.add(:additional_attributes, 'number must contain 11 digits') unless configured_number.to_s.match?(/\A\d{11}\z/)
  end

  def normalize_whatsapp_web_settings!
    return unless whatsapp_web_provider?

    attrs = (additional_attributes || {}).deep_dup.deep_stringify_keys
    normalized_number = normalize_number(attrs['number'] || attrs.dig(EVOLUTION_ATTRIBUTE_KEY, 'number'))

    attrs['provider'] = WHATSAPP_WEB_PROVIDER
    if normalized_number.present?
      attrs['number'] = normalized_number
    else
      attrs.delete('number')
    end

    self.additional_attributes = attrs
    self.webhook_url = default_webhook_url if default_webhook_url.present?
  end

  def normalize_number(value)
    value.to_s.gsub(/\D/, '')
  end

  def evolution_api_url
    ENV.fetch('EVOLUTION_API_URL', '').to_s.chomp('/')
  end
end
