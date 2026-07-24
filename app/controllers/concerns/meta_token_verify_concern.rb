# services from Meta (Prev: Facebook) needs a token verification step for webhook subscriptions,
# This concern handles the token verification step.

module MetaTokenVerifyConcern
  CHANNEL_APP_SECRET_KEYS = %w[app_secret app_secret_key client_secret api_secret].freeze
  META_SIGNATURE_HEADER = 'X-Hub-Signature-256'.freeze
  META_SIGNATURE_PREFIX = 'sha256='.freeze

  def verify
    service = is_a?(Webhooks::WhatsappController) ? 'whatsapp' : 'instagram'
    if valid_verification_request?
      Rails.logger.info("#{service.capitalize} webhook verified")
      render plain: params['hub.challenge']
    else
      render status: :unauthorized, json: { error: 'Error; wrong verify token' }
    end
  end

  private

  def valid_verification_request?
    params['hub.mode'] == 'subscribe' && params['hub.challenge'].present? && valid_token?(params['hub.verify_token'])
  end

  def verify_meta_signature!
    signature_required = meta_signature_verification_required?
    @meta_signature_verified = valid_meta_signature? && meta_signature_scope_valid?
    return if @meta_signature_verified
    return unless signature_required

    head :unauthorized
  end

  def meta_signature_verified?
    @meta_signature_verified == true
  end

  def valid_meta_signature?
    signature = request.headers[META_SIGNATURE_HEADER]
    return false unless signature&.start_with?(META_SIGNATURE_PREFIX)

    meta_app_secrets.any? do |secret|
      next false if secret.blank?

      expected_signature = "#{META_SIGNATURE_PREFIX}#{OpenSSL::HMAC.hexdigest('SHA256', secret, meta_request_body)}"
      next false unless ActiveSupport::SecurityUtils.secure_compare(expected_signature, signature)

      @verified_meta_app_secret_fingerprint = meta_app_secret_fingerprint(secret)
      true
    end
  end

  def meta_signature_scope_valid?
    true
  end

  def verified_meta_app_secret?(secret)
    return false if secret.blank? || @verified_meta_app_secret_fingerprint.blank?

    ActiveSupport::SecurityUtils.secure_compare(
      meta_app_secret_fingerprint(secret),
      @verified_meta_app_secret_fingerprint
    )
  end

  def meta_app_secret_fingerprint(secret)
    OpenSSL::Digest::SHA256.hexdigest(secret.to_s)
  end

  def meta_request_body
    @meta_request_body ||= request.raw_post
  end

  def meta_app_secrets
    raise 'Overwrite this method in your controller'
  end

  def meta_signature_verification_required?
    true
  end

  def channel_meta_app_secrets(channel)
    return [] if channel.blank?

    secrets = []
    secrets << channel.app_secret if channel.respond_to?(:app_secret)
    secrets.concat(provider_config_meta_app_secrets(channel))
    secrets.compact_blank.uniq
  end

  def provider_config_meta_app_secrets(channel)
    return [] unless channel.respond_to?(:provider_config)

    provider_config = channel.provider_config.to_h.with_indifferent_access
    CHANNEL_APP_SECRET_KEYS.filter_map { |key| provider_config[key].presence }
  end

  def valid_token?(_token)
    raise 'Overwrite this method your controller'
  end
end
