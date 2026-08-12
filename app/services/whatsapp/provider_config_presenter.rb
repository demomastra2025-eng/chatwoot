class Whatsapp::ProviderConfigPresenter
  PUBLIC_PROVIDER_CONFIG_KEYS = %w[
    ai_voice_enabled authorization_expires_at authorization_status business_account_id business_id calling_capable
    calling_enabled connection_state coexistence_sync embedded_signup_flow meta_webhook_lifecycle phone_number_id
    phone_registration source status webhook_callback_recovery
  ].freeze
  PUBLIC_COEXISTENCE_SYNC_KEYS = %w[
    state deadline_at request_started_at requested_at failed_at last_error recovery_required_at completed_at
    smb_app_state_sync_request_state smb_app_state_sync_request_started_at smb_app_state_sync_requested_at
    smb_app_state_sync_completed_at smb_app_state_sync_last_error history_request_state history_request_started_at
    history_requested_at history_completed_at history_last_error history_progress history_phase history_chunk_order
    history_last_event_at history_error_at history_errors history_failed_at history_failed_messages
    contacts_last_event_at contacts_events_count contacts_state contacts_last_error contacts_quarantined_events_count
    contacts_quarantine_overflow_count
  ].freeze
  PUBLIC_HISTORY_FAILURE_KEYS = %w[id failure_key kind error replayable].freeze
  PUBLIC_CALLBACK_RECOVERY_KEYS = %w[
    state waba_id subscribed_fields attempt_count last_attempt_at last_error updated_at resolved_at failed_at
    outcome_unknown_at manual_recovery_required_at
  ].freeze
  PUBLIC_LIFECYCLE_KEYS = %w[counters last_event_at].freeze
  PUBLIC_PHONE_REGISTRATION_KEYS = %w[
    status provider_error_code detected_at attempted_at failed_at retry_after_at completed_at
  ].freeze

  def initialize(channel)
    @channel = channel
  end

  def perform
    config = @channel.provider_config.to_h.slice(*PUBLIC_PROVIDER_CONFIG_KEYS)
    project_coexistence_sync!(config)
    project_callback_recovery!(config)
    project_lifecycle!(config)
    project_phone_registration!(config)

    Meta::CredentialDataSanitizer.sanitize(
      config,
      secrets: Meta::CredentialDataSanitizer.channel_secrets(@channel)
    )
  end

  private

  def project_coexistence_sync!(config)
    return if config['coexistence_sync'].blank?

    sync = config['coexistence_sync'].to_h.slice(*PUBLIC_COEXISTENCE_SYNC_KEYS)
    sync['history_failed_messages'] = public_history_failures(sync['history_failed_messages']) if sync['history_failed_messages'].present?
    config['coexistence_sync'] = sync
  end

  def public_history_failures(failures)
    Array(failures).map do |failure|
      failure.to_h.slice(*PUBLIC_HISTORY_FAILURE_KEYS)
    end
  end

  def project_callback_recovery!(config)
    return if config['webhook_callback_recovery'].blank?

    config['webhook_callback_recovery'] = config['webhook_callback_recovery'].to_h.slice(
      *PUBLIC_CALLBACK_RECOVERY_KEYS
    )
  end

  def project_lifecycle!(config)
    return if config['meta_webhook_lifecycle'].blank?

    config['meta_webhook_lifecycle'] = config['meta_webhook_lifecycle'].to_h.slice(
      *PUBLIC_LIFECYCLE_KEYS
    )
  end

  def project_phone_registration!(config)
    return if config['phone_registration'].blank?

    config['phone_registration'] = config['phone_registration'].to_h.slice(*PUBLIC_PHONE_REGISTRATION_KEYS)
  end
end
