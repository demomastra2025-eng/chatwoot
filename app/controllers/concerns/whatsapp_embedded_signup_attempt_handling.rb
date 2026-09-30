# Ties a WhatsApp Embedded Signup completion request to the attempt the dashboard
# registered before opening Meta (see Whatsapp::EmbeddedSignupAttempt). Requests
# without signup_nonce (older clients, reauthorization) keep the previous behaviour.
module WhatsappEmbeddedSignupAttemptHandling
  extend ActiveSupport::Concern

  SIGNUP_ATTEMPT_ALREADY_USED = 'signup_attempt_already_used'.freeze

  private

  def signup_attempt
    return @signup_attempt if defined?(@signup_attempt)

    nonce = params[:signup_nonce].presence
    @signup_attempt = if nonce && params[:inbox_id].blank?
                        Whatsapp::EmbeddedSignupAttempt.new(account: Current.account, user: Current.user, nonce: nonce)
                      end
  end

  # Only a client that sends an attempt nonce may omit waba_id: the server then reads the WABA
  # the customer shared from the business token (mobile popup lost the session event).
  # Registration is best effort (a suspended tab may drop it), so the claim below does
  # not require it; the nonce still makes the completion single-use per account+user.
  def resolve_waba_from_token?
    signup_attempt.present? && params[:waba_id].blank?
  end

  # Returns false after rendering 409 when the attempt was already used (replay or a
  # second completion path racing the first one).
  def claim_signup_attempt
    return true if signup_attempt.nil?
    return @signup_attempt_claimed = true if signup_attempt.claim(signup_type: params[:signup_type])

    log_signup_attempt('replay_rejected')
    render json: { success: false, error: 'This WhatsApp connection attempt was already processed',
                   error_code: SIGNUP_ATTEMPT_ALREADY_USED }, status: :conflict
    false
  end

  def complete_signup_attempt(channel, service)
    return unless @signup_attempt_claimed

    signup_attempt.complete!(channel.inbox.id)
    log_signup_attempt('completed', waba_source: service.waba_source)
  rescue StandardError => e
    # The channel exists; a Redis hiccup must not turn a successful signup into an error.
    Rails.logger.error("[WHATSAPP AUTHORIZATION] Failed to record signup attempt completion: #{e.class}")
  end

  def fail_signup_attempt(error_code)
    return unless @signup_attempt_claimed

    signup_attempt.fail!(error_code)
    log_signup_attempt('failed', error_code: error_code)
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP AUTHORIZATION] Failed to record signup attempt failure: #{e.class}")
  end

  def signup_attempt_error_details(error)
    case error
    when Whatsapp::EmbeddedSignupAttempt::InvalidNonceError
      { error_code: 'invalid_signup_attempt' }
    when Whatsapp::EmbeddedSignupWabaResolver::ResolutionError
      { error_code: error.error_code }
    end
  end

  def signup_attempt_client_safe_error?(error)
    error.is_a?(Whatsapp::EmbeddedSignupAttempt::InvalidNonceError) ||
      error.is_a?(Whatsapp::EmbeddedSignupWabaResolver::ResolutionError)
  end

  def log_signup_attempt(phase, **details)
    Rails.logger.info(
      {
        event: 'whatsapp_embedded_signup_attempt',
        phase: phase,
        account_id: Current.account.id,
        user_id: Current.user&.id,
        attempt: signup_attempt&.reference,
        signup_type: params[:signup_type].presence,
        code_only: params[:waba_id].blank?
      }.merge(details).compact.to_json
    )
  end
end
