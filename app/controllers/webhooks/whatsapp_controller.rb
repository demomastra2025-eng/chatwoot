class Webhooks::WhatsappController < ActionController::API
  include MetaTokenVerifyConcern

  def process_payload
    log_webhook_request

    if inactive_whatsapp_number?
      Rails.logger.warn("Rejected webhook for inactive WhatsApp number: #{params[:phone_number]}")
      render json: { error: 'Inactive WhatsApp number' }, status: :unprocessable_content
      return
    end

    Webhooks::WhatsappEventsJob.perform_later(params.to_unsafe_hash)
    head :ok
  end

  private

  def valid_token?(token)
    channel = Channel::Whatsapp.find_by(phone_number: params[:phone_number])
    whatsapp_webhook_verify_token = channel.provider_config['webhook_verify_token'] if channel.present?
    token == whatsapp_webhook_verify_token if whatsapp_webhook_verify_token.present?
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

    Rails.logger.info(
      "[WHATSAPP_WEBHOOK] received " \
      "request_id=#{request.request_id} " \
      "phone_number=#{params[:phone_number]} " \
      "object=#{params[:object] || 'unknown'} " \
      "entries=#{Array(params[:entry]).size} " \
      "changes=#{changes.size} " \
      "fields=#{fields.join(',')} " \
      "messages=#{values.sum { |value| Array(value[:messages] || value['messages']).size }} " \
      "statuses=#{values.sum { |value| Array(value[:statuses] || value['statuses']).size }} " \
      "contacts=#{values.sum { |value| Array(value[:contacts] || value['contacts']).size }} " \
      "echoes=#{values.sum { |value| Array(value[:message_echoes] || value['message_echoes']).size }}"
    )
  end

  def webhook_changes
    Array(params[:entry]).flat_map do |entry|
      Array(entry[:changes] || entry['changes'])
    end
  end
end
