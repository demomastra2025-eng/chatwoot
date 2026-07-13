# frozen_string_literal: true

class Meta::ChannelCredentialHealthCheckService
  def initialize(channel)
    @channel = channel
  end

  def perform
    refresh_instagram_token_if_needed
    provider_reauthorization = provider_reauthorization_recorded?
    result = Meta::AuthorizationHealthCheckService.new(@channel).result
    result = repair_subscription(result) if result.degraded? && result.reason == 'subscription_missing'

    Meta::ChannelCredentialHealthRecorder.new(@channel).record_result!(result)
    apply_reauthorization_state(result, provider_reauthorization: provider_reauthorization)
    result
  end

  private

  def refresh_instagram_token_if_needed
    return unless @channel.is_a?(Channel::Instagram)

    @channel.access_token
  end

  def repair_subscription(result)
    response = subscription_response
    return repaired_subscription_result(result) if successful_subscription_response?(response)

    raise "Subscription repair failed with HTTP #{response.respond_to?(:code) ? response.code : 'unknown'}"
  rescue StandardError => e
    failed_subscription_result(result, e)
  end

  def subscription_response
    return @channel.subscribe(raise_on_error: true) unless @channel.is_a?(Channel::Instagram)

    @channel.subscribe(raise_on_error: true, access_token: @channel[:access_token])
  end

  def successful_subscription_response?(response)
    response == true || (response.respond_to?(:success?) && response.success?)
  end

  def repaired_subscription_result(result)
    Meta::AuthorizationHealthCheckService::Result.new(
      status: :healthy,
      reason: 'subscription_repaired',
      metadata: result.metadata.to_h.merge('subscription_present' => true, 'subscription_repaired_at' => Time.current.iso8601)
    )
  end

  def failed_subscription_result(result, error)
    classification = Meta::AuthorizationErrorClassifier.classify(error: { message: safe_message(error.message) })
    Meta::AuthorizationHealthCheckService::Result.new(
      status: classification.action_required? ? :action_required : :transient_failure,
      reason: classification.action_required? ? 'subscription_authorization_failed' : 'subscription_repair_failed',
      error: classification.error.presence || { 'type' => error.class.name, 'message' => safe_message(error.message) },
      metadata: result.metadata
    )
  end

  def apply_reauthorization_state(result, provider_reauthorization:)
    if result.action_required?
      @channel.prompt_reauthorization!
    elsif result.healthy? && @channel.reauthorization_required? && provider_reauthorization
      @channel.after_provider_authorization_healthy! if @channel.respond_to?(:after_provider_authorization_healthy!)
      @channel.reauthorized!
    end
  end

  def provider_reauthorization_recorded?
    return true if @channel.respond_to?(:provider_authorization_reauthorization_recorded?) &&
                   @channel.provider_authorization_reauthorization_recorded?
    return true if @channel.authorization_error_count.positive?

    @channel.meta_credential_health&.status == 'action_required'
  end

  def safe_message(message)
    secrets = Meta::CredentialDataSanitizer.channel_secrets(@channel)
    Meta::CredentialDataSanitizer.sanitize(message.to_s.first(500), secrets: secrets)
  end
end
