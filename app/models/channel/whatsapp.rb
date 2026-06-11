# == Schema Information
#
# Table name: channel_whatsapp
#
#  id                             :bigint           not null, primary key
#  message_templates              :jsonb
#  message_templates_last_updated :datetime
#  phone_number                   :string           not null
#  provider                       :string           default("default")
#  provider_config                :jsonb
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  account_id                     :integer          not null
#
# Indexes
#
#  index_channel_whatsapp_on_phone_number  (phone_number) UNIQUE
#

class Channel::Whatsapp < ApplicationRecord
  include Channelable
  include Reauthorizable

  self.table_name = 'channel_whatsapp'
  EDITABLE_ATTRS = [:phone_number, :provider, { provider_config: {} }].freeze

  # default at the moment is 360dialog lets change later.
  PROVIDERS = %w[default whatsapp_cloud].freeze
  AUTHORIZATION_FAILURE_CONFIG_KEYS = %w[authorization_status authorization_error].freeze
  TOKEN_HEALTH_CONFIG_KEY = 'token_health'.freeze
  AUTHORIZATION_ERROR_CODE = 190
  before_validation :ensure_webhook_verify_token

  validates :provider, inclusion: { in: PROVIDERS }
  validates :phone_number, presence: true, uniqueness: true
  validate :validate_provider_config

  after_create :sync_templates
  before_destroy :teardown_webhooks
  after_commit :setup_webhooks, on: :create, if: :should_auto_setup_webhooks?

  def name
    'Whatsapp'
  end

  # Meta WhatsApp Calling is only available for Cloud API channels provisioned
  # through embedded signup and explicitly enabled for calling.
  def voice_enabled?
    provider == 'whatsapp_cloud' &&
      provider_config['source'] == 'embedded_signup' &&
      calling_enabled? &&
      account.feature_enabled?('whatsapp_call')
  end

  def calling_enabled?
    return ActiveModel::Type::Boolean.new.cast(provider_config['calling_enabled']) if provider_config.key?('calling_enabled')

    ActiveModel::Type::Boolean.new.cast(provider_config['calling_capable'])
  end

  def provider_service
    if provider == 'whatsapp_cloud'
      Whatsapp::Providers::WhatsappCloudService.new(whatsapp_channel: self)
    else
      Whatsapp::Providers::Whatsapp360DialogService.new(whatsapp_channel: self)
    end
  end

  def mark_message_templates_updated
    # rubocop:disable Rails/SkipsModelValidations
    update_column(:message_templates_last_updated, Time.zone.now)
    # rubocop:enable Rails/SkipsModelValidations
  end

  delegate :send_message, to: :provider_service
  delegate :send_template, to: :provider_service
  delegate :sync_templates, to: :provider_service
  delegate :media_url, to: :provider_service
  delegate :api_headers, to: :provider_service

  def setup_webhooks(strict: false)
    perform_webhook_setup(strict: strict)
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Webhook setup failed: #{e.message}"
    prompt_reauthorization!
    raise if strict
  end

  def record_provider_authorization_error!(payload)
    error_payload = self.class.provider_authorization_error(payload)
    return false unless error_payload

    record_reauthorization_error!(error_payload)
    true
  end

  def record_provider_configuration_error!(message, code: nil, type: 'ConfigurationError')
    return false if message.blank?

    record_reauthorization_error!(
      {
        'code' => code,
        'type' => type,
        'message' => message,
        'recorded_at' => Time.current.iso8601
      }.compact
    )
    true
  end

  def provider_authorization_error_recorded?
    provider_config.to_h['authorization_status'] == 'reauthorization_required' &&
      provider_config.to_h['authorization_error'].present?
  end

  def clear_provider_authorization_error!
    return false if provider_config.to_h.slice(*AUTHORIZATION_FAILURE_CONFIG_KEYS).empty?

    # rubocop:disable Rails/SkipsModelValidations
    update_column(:provider_config, provider_config.to_h.except(*AUTHORIZATION_FAILURE_CONFIG_KEYS))
    # rubocop:enable Rails/SkipsModelValidations
    true
  end

  def store_token_health!(metadata)
    return false if metadata.blank?

    updated_config = provider_config.to_h.merge(TOKEN_HEALTH_CONFIG_KEY => metadata.to_h.deep_stringify_keys)

    if persisted?
      # rubocop:disable Rails/SkipsModelValidations
      update_column(:provider_config, updated_config)
      # rubocop:enable Rails/SkipsModelValidations
    else
      self.provider_config = updated_config
    end

    true
  end

  def self.provider_authorization_error(payload)
    error = normalize_provider_error(payload)
    return nil unless provider_authorization_error?(error)

    {
      'code' => error['code'],
      'type' => error['type'],
      'message' => error['message'],
      'fbtrace_id' => error['fbtrace_id'],
      'recorded_at' => Time.current.iso8601
    }.compact
  end

  def self.normalize_provider_error(payload)
    return {} if payload.blank?
    return {} unless payload.respond_to?(:to_h)

    payload = payload.to_h.with_indifferent_access
    error = payload[:error] || payload['error'] || payload
    error.to_h.stringify_keys
  end

  def self.provider_authorization_error?(error)
    return true if error['code'].to_i == AUTHORIZATION_ERROR_CODE
    return false unless error['type'] == 'OAuthException'

    error['message'].to_s.match?(/access token|session has expired|validating access token/i)
  end

  private

  def record_reauthorization_error!(error_payload)
    already_requires_reauthorization = reauthorization_required?
    # rubocop:disable Rails/SkipsModelValidations
    update_column(
      :provider_config,
      provider_config.to_h.merge(
        'authorization_status' => 'reauthorization_required',
        'authorization_error' => error_payload
      )
    )
    # rubocop:enable Rails/SkipsModelValidations
    prompt_reauthorization! unless already_requires_reauthorization
  end

  def ensure_webhook_verify_token
    provider_config['webhook_verify_token'] ||= SecureRandom.hex(16) if provider == 'whatsapp_cloud'
  end

  def validate_provider_config
    errors.add(:provider_config, 'Invalid Credentials') unless provider_service.validate_provider_config?
  end

  def perform_webhook_setup(strict: false)
    business_account_id = provider_config['business_account_id']
    api_key = provider_config['api_key']

    Whatsapp::WebhookSetupService.new(self, business_account_id, api_key, strict: strict).perform
  end

  def teardown_webhooks
    Whatsapp::WebhookTeardownService.new(self).perform
  end

  def should_auto_setup_webhooks?
    # Only auto-setup webhooks for whatsapp_cloud provider with manual setup
    # Embedded signup calls setup_webhooks explicitly in EmbeddedSignupService
    provider == 'whatsapp_cloud' && provider_config['source'] != 'embedded_signup'
  end
end
