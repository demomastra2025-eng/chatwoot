class Telephony::CallRecordingPlaybackUrl
  TOKEN_PARAM = :recording_token
  PURPOSE = :telephony_call_recording_playback

  def self.path_for(call_session, storage_key:)
    path_params = {
      account_id: call_session.account_id,
      call_ref: call_session.external_call_ref
    }
    path_params[TOKEN_PARAM] = token_for(call_session, storage_key: storage_key)

    Rails.application.routes.url_helpers.recording_api_v1_account_telephony_call_path(
      path_params
    )
  end

  def self.token_for(call_session, storage_key:)
    verifier.generate(payload_for(call_session, storage_key: storage_key), purpose: PURPOSE)
  end

  def self.valid?(token:, call_session:, storage_key:)
    payload = verifier.verified(token.to_s, purpose: PURPOSE)
    return false unless payload.is_a?(Hash)

    payload = payload.with_indifferent_access
    payload[:account_id].to_i == call_session.account_id &&
      payload[:call_session_id].to_i == call_session.id &&
      payload[:call_ref].to_s == call_session.external_call_ref.to_s &&
      payload[:storage_key].to_s == storage_key.to_s
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    false
  end

  def self.payload_for(call_session, storage_key:)
    {
      account_id: call_session.account_id,
      call_session_id: call_session.id,
      call_ref: call_session.external_call_ref,
      storage_key: storage_key
    }
  end

  def self.verifier
    Rails.application.message_verifier(:telephony_call_recording_playback)
  end

  private_class_method :payload_for, :verifier
end
