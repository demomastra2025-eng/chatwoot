# frozen_string_literal: true

class Meta::AuthorizationErrorHandler
  def self.handle(channel:, payload:, http_status: nil)
    classification = Meta::AuthorizationErrorClassifier.classify(payload, http_status: http_status)
    return classification unless classification.kind == :reauthorization_required

    if classification.confirmed_invalid?
      record_confirmed_invalidation(channel, classification)
      channel.prompt_reauthorization!
    else
      channel.authorization_error!
    end

    classification
  end

  def self.record_confirmed_invalidation(channel, classification)
    result = Meta::AuthorizationHealthCheckService::Result.new(
      status: :action_required,
      reason: 'provider_authorization_failed',
      error: classification.error,
      metadata: { 'checked_at' => Time.current.iso8601 }
    )
    Meta::ChannelCredentialHealthRecorder.new(channel).record_result!(result)
  end
  private_class_method :record_confirmed_invalidation
end
