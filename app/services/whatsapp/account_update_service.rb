# frozen_string_literal: true

class Whatsapp::AccountUpdateService
  REAUTHORIZATION_EVENTS = %w[
    ACCOUNT_DELETED ACCOUNT_OFFBOARDED PARTNER_APP_UNINSTALLED PARTNER_REMOVED
  ].freeze
  RECOVERY_EVENTS = %w[ACCOUNT_RECONNECTED PARTNER_ADDED PARTNER_APP_INSTALLED].freeze
  POLICY_EVENTS = %w[ACCOUNT_RESTRICTION ACCOUNT_VIOLATION DISABLED_UPDATE].freeze

  def initialize(channel:, params:)
    @channel = channel
    @params = params.to_h.with_indifferent_access
  end

  def perform
    account_update_changes.each do |entry, change|
      process_change(entry, change)
    end
  end

  private

  def account_update_changes
    Array(@params[:entry]).flat_map do |entry|
      Array(entry[:changes]).filter_map do |change|
        [entry, change] if change[:field] == 'account_update'
      end
    end
  end

  def process_change(entry, change)
    return unless matching_waba?(entry[:id])

    value = change[:value].to_h.with_indifferent_access
    event = value[:event].to_s
    return if event.blank?

    metadata = lifecycle_metadata(entry, value, event)
    return if @channel.provider_lifecycle_event_recorded?(metadata['fingerprint'])

    if REAUTHORIZATION_EVENTS.include?(event)
      @channel.record_provider_configuration_error!(
        "WhatsApp account lifecycle requires reconnection: #{event}",
        type: 'WhatsAppAccountUpdate'
      )
    elsif RECOVERY_EVENTS.include?(event)
      Whatsapp::TokenHealthCheckChannelJob.perform_later(@channel.id)
    elsif POLICY_EVENTS.include?(event)
      record_policy_restriction(event, metadata)
    end

    @channel.store_provider_lifecycle_event!(metadata)
  end

  def matching_waba?(payload_waba_id)
    configured_waba_id = @channel.provider_config.to_h['business_account_id'].to_s
    return true if configured_waba_id.present? && configured_waba_id == payload_waba_id.to_s

    Rails.logger.warn(
      "[WHATSAPP ACCOUNT UPDATE] WABA mismatch channel=#{@channel.id} " \
      "expected=#{configured_waba_id.presence || 'missing'} actual=#{payload_waba_id}"
    )
    false
  end

  def lifecycle_metadata(entry, value, event)
    metadata = {
      'event' => event,
      'waba_id' => entry[:id].to_s,
      'provider_time' => entry[:time],
      'disconnection_reason' => value.dig(:disconnection_info, :reason),
      'disconnection_initiated_by' => value.dig(:disconnection_info, :initiated_by),
      'violation_type' => value.dig(:violation_info, :violation_type),
      'restriction_types' => Array(value[:restriction_info]).filter_map { |item| item[:restriction_type] },
      'recorded_at' => Time.current.iso8601
    }.compact
    metadata['fingerprint'] = Digest::SHA256.hexdigest(metadata.except('recorded_at').to_json)
    metadata
  end

  def record_policy_restriction(event, metadata)
    result = Meta::AuthorizationHealthCheckService::Result.new(
      status: :action_required,
      reason: 'policy_restricted',
      error: { 'type' => 'WhatsAppAccountUpdate', 'message' => event },
      metadata: metadata
    )
    Meta::ChannelCredentialHealthRecorder.new(@channel).record_result!(result)
  end
end
