module WhatsappWebhookAuthenticationConcern
  META_SECRET_CHANNEL_LIMIT = 100
  META_WABA_ID_LIMIT = 20

  private

  def valid_token?(token)
    return explicit_callback_token_valid?(token) if request.path_parameters[:phone_number].present?
    return channel_verify_token_matches?(manual_callback_channel, token) if request.query_parameters['channel_id'].present?

    global_verify_token = GlobalConfigService.load('WHATSAPP_WEBHOOK_VERIFY_TOKEN', nil)
    global_verify_token.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, global_verify_token.to_s)
  end

  def meta_app_secrets
    return [] if webhook_waba_ids.size > META_WABA_ID_LIMIT

    channel = whatsapp_channel unless default_callback?
    return [] if channel.present? && !webhook_matches_channel_waba?(channel)

    [
      *(default_callback? ? waba_meta_app_secrets : channel_meta_app_secrets(channel)),
      GlobalConfigService.load('WHATSAPP_APP_SECRET', nil)
    ].compact_blank.uniq
  end

  def meta_signature_scope_valid?
    return true unless default_callback?
    return true if verified_meta_app_secret?(GlobalConfigService.load('WHATSAPP_APP_SECRET', nil))

    webhook_waba_ids.present? && webhook_waba_ids.all? do |waba_id|
      Array(waba_secret_candidates[waba_id]).any? do |candidate|
        channel_meta_app_secrets(candidate).any? { |secret| verified_meta_app_secret?(secret) }
      end
    end
  end

  def explicit_callback_token_valid?(token)
    channel = Channel::Whatsapp.find_by(phone_number: request.path_parameters[:phone_number])
    channel_verify_token_matches?(channel, token)
  end

  def waba_meta_app_secrets
    return [] if webhook_waba_ids.empty?

    waba_secret_candidates.values.flatten.flat_map { |candidate| channel_meta_app_secrets(candidate) }.uniq
  end

  def waba_secret_candidates
    return @waba_secret_candidates if defined?(@waba_secret_candidates)

    candidates = Channel::Whatsapp.lifecycle_cloud.for_waba(webhook_waba_ids).limit(META_SECRET_CHANNEL_LIMIT).to_a
    @waba_secret_candidates = candidates.group_by do |candidate|
      candidate.provider_config.to_h['business_account_id'].to_s
    end
  end

  def manual_callback_channel
    channel_id = request.query_parameters['channel_id']
    return if channel_id.blank?

    Channel::Whatsapp.active_cloud.find_by(id: channel_id)
  end

  def channel_verify_token_matches?(channel, token)
    verify_token = channel&.provider_config.to_h&.[]('webhook_verify_token')
    verify_token.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, verify_token.to_s)
  end
end
