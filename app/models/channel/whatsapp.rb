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
  include Whatsapp::DurableReauthorization
  include WhatsappProviderLifecycle
  include WhatsappChannelRouting

  self.table_name = 'channel_whatsapp'
  EDITABLE_ATTRS = [:phone_number, :provider, { provider_config: {} }].freeze

  # default at the moment is 360dialog lets change later.
  PROVIDERS = %w[default whatsapp_cloud].freeze
  PROVIDER_LIFECYCLE_CONFIG_KEY = 'provider_lifecycle'.freeze
  AUTHORIZATION_ERROR_CODE = 190

  before_validation :ensure_webhook_verify_token

  validates :provider, inclusion: { in: PROVIDERS }
  validates :phone_number, presence: true, uniqueness: true
  validate :validate_provider_config
  validate ->(channel) { Whatsapp::WabaRoutingOwnershipValidator.new(channel).validate }, unless: :skip_waba_routing_ownership_validation

  has_one :meta_credential_health,
          as: :channel,
          class_name: 'Meta::ChannelCredentialHealth',
          dependent: :destroy

  after_create :sync_templates
  before_destroy :teardown_webhooks, unless: :skip_webhook_teardown
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

  def update_message_templates_cache!(templates)
    # Provider template sync already validated the upstream payload. Avoid running
    # provider validations again, but still invalidate the inbox cache observed by
    # active browser sessions.
    # rubocop:disable Rails/SkipsModelValidations
    updated = update_columns(
      message_templates: templates,
      message_templates_last_updated: Time.current.utc
    )
    # rubocop:enable Rails/SkipsModelValidations
    inbox&.update_account_cache if updated
    updated
  end

  delegate :send_message, to: :provider_service
  delegate :send_template, to: :provider_service
  delegate :sync_templates, to: :provider_service
  delegate :media_url, to: :provider_service
  delegate :api_headers, to: :provider_service

  def setup_webhooks(strict: false, force_registration: false)
    perform_webhook_setup(strict: strict, force_registration: force_registration)
  rescue StandardError => e
    safe_message = sanitize_provider_metadata('message' => e.message)['message']
    Rails.logger.error "[WHATSAPP] Webhook setup failed: #{safe_message}"
    prompt_reauthorization!
    raise if strict
  end

  def record_provider_authorization_error!(payload)
    error_payload = self.class.provider_authorization_error(payload)
    return false unless error_payload
    return false if provider_authorization_healthy_after_error?

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

    mutate_provider_config! { |config| config.except(*AUTHORIZATION_FAILURE_CONFIG_KEYS) }
    true
  end

  def store_token_health!(metadata)
    return false if metadata.blank?

    safe_metadata = sanitize_provider_metadata(metadata)
    if persisted?
      mutate_provider_config! do |config|
        config.merge(TOKEN_HEALTH_CONFIG_KEY => safe_metadata)
      end
    else
      self.provider_config = provider_config.to_h.merge(TOKEN_HEALTH_CONFIG_KEY => safe_metadata)
    end

    true
  end

  def provider_authorization_healthy?
    provider_authorization_health_service.healthy?
  end

  def provider_authorization_transient_failure?
    return false unless provider_authorization_health_service.respond_to?(:result)

    provider_authorization_health_service.result.transient?
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
    Meta::AuthorizationErrorClassifier.classify(error).kind == :reauthorization_required
  end

  private

  def provider_authorization_health_service
    @provider_authorization_health_service ||= Meta::AuthorizationHealthCheckService.new(self)
  end

  def record_reauthorization_error!(error_payload)
    already_requires_reauthorization = reauthorization_required?
    safe_error_payload = sanitize_provider_metadata(error_payload)
    mutate_provider_config! do |config|
      config.merge(
        'authorization_status' => 'reauthorization_required',
        'authorization_error' => safe_error_payload
      )
    end
    prompt_reauthorization! unless already_requires_reauthorization
  end

  def mutate_provider_config!
    with_lock do
      reload
      updated_config = yield(provider_config.to_h.deep_dup)
      # rubocop:disable Rails/SkipsModelValidations
      update_column(:provider_config, updated_config)
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  def ensure_webhook_verify_token
    provider_config['webhook_verify_token'] ||= SecureRandom.hex(16) if provider == 'whatsapp_cloud'
  end

  def validate_provider_config
    errors.add(:provider_config, 'Invalid Credentials') unless provider_service.validate_provider_config?
  end

  def perform_webhook_setup(strict: false, force_registration: false)
    business_account_id = provider_config['business_account_id']
    api_key = provider_config['api_key']
    options = { strict: strict, force_registration: force_registration }
    Whatsapp::WebhookSetupService.new(self, business_account_id, api_key, **options).perform
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
