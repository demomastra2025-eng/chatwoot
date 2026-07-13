class Webhooks::WhatsappController < ActionController::API
  include MetaTokenVerifyConcern

  before_action :verify_meta_signature!, only: :process_payload

  def process_payload
    log_webhook_request

    if inactive_whatsapp_number?
      Rails.logger.warn("Rejected webhook for inactive WhatsApp number: #{params[:phone_number]}")
      render json: { error: 'Inactive WhatsApp number' }, status: :unprocessable_content
      return
    end

    Webhooks::WhatsappEventsJob.perform_later(
      params.to_unsafe_hash,
      { hmac_verified: meta_signature_verified? }
    )
    head :ok
  end

  private

  def valid_token?(token)
    channel = Channel::Whatsapp.find_by(phone_number: params[:phone_number])
    whatsapp_webhook_verify_token = channel.provider_config['webhook_verify_token'] if channel.present?
    token == whatsapp_webhook_verify_token if whatsapp_webhook_verify_token.present?
  end

  def meta_app_secrets
    [
      *channel_meta_app_secrets(whatsapp_channel),
      GlobalConfigService.load('WHATSAPP_APP_SECRET', nil)
    ]
  end

  def whatsapp_channel
    @whatsapp_channel ||= whatsapp_business_payload_channel || Channel::Whatsapp.find_by(phone_number: params[:phone_number])
  end

  def meta_signature_verification_required?
    return true if whatsapp_channel.blank?
    return false unless whatsapp_channel.provider == 'whatsapp_cloud'
    return true if meta_app_secrets.compact_blank.present?
    return true if embedded_signup_channel?

    Rails.logger.warn("[WHATSAPP_WEBHOOK] skipping HMAC validation: missing app secret for channel=#{whatsapp_channel.id}")
    false
  end

  def embedded_signup_channel?
    whatsapp_channel.provider_config.to_h.with_indifferent_access[:source] == 'embedded_signup'
  end

  def whatsapp_business_payload_channel
    return unless params[:object] == 'whatsapp_business_account'

    metadata = params.dig(:entry, 0, :changes, 0, :value, :metadata)
    return if metadata.blank?

    phone_number = normalized_phone_number(metadata[:display_phone_number])
    phone_number_id = metadata[:phone_number_id]
    channel = Channel::Whatsapp.find_by(phone_number: phone_number)

    return channel if channel && channel.provider_config['phone_number_id'] == phone_number_id
  end

  def normalized_phone_number(phone_number)
    return if phone_number.blank?

    phone_number = phone_number.to_s
    phone_number.start_with?('+') ? phone_number : "+#{phone_number}"
  end

  def inactive_whatsapp_number?
    phone_number = params[:phone_number]
    return false if phone_number.blank?

    inactive_numbers = GlobalConfig.get_value('INACTIVE_WHATSAPP_NUMBERS').to_s
    return false if inactive_numbers.blank?

    inactive_numbers_array = inactive_numbers.split(',').map(&:strip)
    inactive_numbers_array.include?(phone_number)
  end

  def log_webhook_request
    changes = webhook_changes
    values = changes.filter_map { |change| change[:value] || change['value'] }
    fields = changes.filter_map { |change| change[:field] || change['field'] }.uniq

    Rails.logger.info(webhook_log_parts(changes, values, fields).join(' '))
  end

  def webhook_log_parts(changes, values, fields)
    [
      '[WHATSAPP_WEBHOOK] received',
      "request_id=#{request.request_id}",
      "phone_number=#{params[:phone_number]}",
      "object=#{params[:object] || 'unknown'}",
      "entries=#{Array(params[:entry]).size}",
      "changes=#{changes.size}",
      "fields=#{fields.join(',')}",
      "messages=#{webhook_value_count(values, :messages)}",
      "statuses=#{webhook_value_count(values, :statuses)}",
      "contacts=#{webhook_value_count(values, :contacts)}",
      "echoes=#{webhook_value_count(values, :message_echoes)}"
    ]
  end

  def webhook_value_count(values, key)
    values.sum { |value| Array(value[key] || value[key.to_s]).size }
  end

  def webhook_changes
    Array(params[:entry]).flat_map do |entry|
      Array(entry[:changes] || entry['changes'])
    end
  end
end
