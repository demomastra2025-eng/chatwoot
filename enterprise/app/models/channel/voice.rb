# == Schema Information
#
# Table name: channel_voice
#
#  id                    :bigint           not null, primary key
#  additional_attributes :jsonb
#  phone_number          :string           not null
#  provider              :string           default("twilio"), not null
#  provider_config       :jsonb            not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :integer          not null
#
# Indexes
#
#  index_channel_voice_on_account_id    (account_id)
#  index_channel_voice_on_phone_number  (phone_number) UNIQUE
#
class Channel::Voice < ApplicationRecord
  include Channelable

  self.table_name = 'channel_voice'

  CURRENT_FONOSTER_OPERATOR_AGENT_AOR = 'sip:1001@operator.cloud.vconsult.kz'.freeze
  STALE_FONOSTER_OPERATOR_AGENT_AORS = ['sip:1001@company.example'].freeze

  PROVIDERS = %w[twilio fonoster sipuni].freeze

  validates :phone_number, presence: true, uniqueness: true
  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :provider_config, presence: true

  # Validate phone number format (E.164 format)
  validates :phone_number, format: { with: /\A\+[1-9]\d{1,14}\z/ }

  # Provider-specific configs stored in JSON
  validate :validate_provider_config
  before_validation :provision_twilio_on_create, on: :create, if: :twilio?
  after_commit :sync_telephony_binding, on: %i[create update], if: :native_telephony_provider?

  EDITABLE_ATTRS = [:phone_number, :provider, { provider_config: {} }].freeze

  def name
    "Voice (#{phone_number})"
  end

  def messaging_window_enabled?
    false
  end

  def initiate_call(to:, conference_sid: nil, agent_id: nil)
    voice_provider_adapter.initiate_call(
      to: to,
      conference_sid: conference_sid,
      agent_id: agent_id
    )
  end

  # Public URLs used to configure Twilio webhooks
  def voice_call_webhook_url
    digits = phone_number.delete_prefix('+')
    Rails.application.routes.url_helpers.twilio_voice_call_url(phone: digits)
  end

  def voice_status_webhook_url
    digits = phone_number.delete_prefix('+')
    Rails.application.routes.url_helpers.twilio_voice_status_url(phone: digits)
  end

  def provider_config_hash
    if provider_config.is_a?(Hash)
      provider_config
    else
      JSON.parse(provider_config.to_s)
    end
  end

  private

  def twilio?
    provider == 'twilio'
  end

  def fonoster?
    provider == 'fonoster'
  end

  def validate_provider_config
    return if provider_config.blank?

    case provider
    when 'twilio'
      validate_twilio_config
    when 'fonoster'
      validate_fonoster_config
    when 'sipuni'
      validate_sipuni_config
    end
  end

  def validate_twilio_config
    config = provider_config.with_indifferent_access
    # Require credentials and provisioned TwiML App SID
    required_keys = %w[account_sid auth_token api_key_sid api_key_secret twiml_app_sid]
    required_keys.each do |key|
      errors.add(:provider_config, "#{key} is required for Twilio provider") if config[key].blank?
    end
  end

  def validate_fonoster_config
    config = provider_config.with_indifferent_access
    routing_mode = config[:routing_mode].to_s.presence || 'operator'
    operator_distribution_mode = Telephony::RoutingPolicy.normalized_operator_distribution_mode(config[:operator_distribution_mode])
    operator_agent_aor = normalized_fonoster_operator_agent_aor(config[:operator_agent_aor])
    config[:operator_agent_aor] = operator_agent_aor if operator_agent_aor.present?
    config[:operator_distribution_mode] = operator_distribution_mode
    self.provider_config = config

    errors.add(:provider_config, 'number_ref is required for Fonoster provider') if config[:number_ref].blank? && config[:fonoster_number_ref].blank?
    errors.add(:provider_config, 'routing_mode must be one of operator, app, ai, reject') unless routing_mode.in?(%w[operator app ai reject])

    if (routing_mode == 'ai' || config[:fallback_mode].to_s == 'ai') && config[:ai_app_ref].blank?
      errors.add(:provider_config, 'ai_app_ref is required for AI routing or fallback')
    end

    errors.add(:provider_config, 'app_ref is required when routing_mode is app') if routing_mode == 'app' && config[:app_ref].blank?

    return unless routing_mode == 'operator' && operator_distribution_mode == Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_TARGETED
    return if config[:operator_agent_aor].present? || config[:operator_agent_ref].present?

    errors.add(:provider_config, 'operator_agent_aor or operator_agent_ref is required when targeted operator routing is selected')
  end

  def validate_sipuni_config
    config = provider_config.with_indifferent_access
    routing_mode = config[:routing_mode].to_s.presence || 'operator'
    operator_distribution_mode = Telephony::RoutingPolicy.normalized_operator_distribution_mode(config[:operator_distribution_mode])
    config[:provider_kind] = 'sipuni'
    config[:operator_distribution_mode] = operator_distribution_mode
    self.provider_config = config

    errors.add(:provider_config, 'number_ref is required for Sipuni provider') if config[:number_ref].blank?
    errors.add(:provider_config, 'provider_connection_id is required for Sipuni provider') if config[:provider_connection_id].blank?
    errors.add(:provider_config, 'routing_mode must be one of operator, app, ai, reject') unless routing_mode.in?(%w[operator app ai reject])
  end

  def normalized_fonoster_operator_agent_aor(value)
    candidate = value.to_s.strip.presence
    return if candidate.blank?
    return CURRENT_FONOSTER_OPERATOR_AGENT_AOR if STALE_FONOSTER_OPERATOR_AGENT_AORS.include?(candidate)

    candidate
  end

  def voice_provider_adapter
    case provider
    when 'twilio'
      Voice::Provider::Twilio::Adapter.new(self)
    when 'fonoster'
      Voice::Provider::Fonoster::Adapter.new(self)
    else
      raise "Unsupported voice provider: #{provider}"
    end
  end

  def provision_twilio_on_create
    service = ::Twilio::VoiceWebhookSetupService.new(channel: self)
    app_sid = service.perform
    return if app_sid.blank?

    cfg = provider_config.with_indifferent_access
    cfg[:twiml_app_sid] = app_sid
    self.provider_config = cfg
  rescue StandardError => e
    error_details = {
      error_class: e.class.to_s,
      message: e.message,
      phone_number: phone_number,
      account_id: account_id,
      backtrace: e.backtrace&.first(5)
    }
    Rails.logger.error("TWILIO_VOICE_SETUP_ON_CREATE_ERROR: #{error_details}")
    errors.add(:base, "Twilio setup failed: #{e.message}")
  end

  def native_telephony_provider?
    provider.in?(%w[fonoster sipuni])
  end

  def sync_telephony_binding
    Telephony::NumberBinding.sync_from_voice_channel!(self)
  rescue StandardError => e
    Rails.logger.error("VOICE_BINDING_SYNC_ERROR provider=#{provider} channel_id=#{id} account_id=#{account_id} message=#{e.message}")
    raise
  end

  public :provider_config_hash
end
