class Sms::DeliveryStatusService
  pattr_initialize [:inbox!, :params!]

  def perform
    return unless supported_status?

    process_status
  end

  private

  def process_status
    process_message_status if message.present?
    process_campaign_delivery_status if campaign_delivery.present?
  end

  def process_message_status
    @message.status = status
    @message.external_error = external_error if error_occurred?
    @message.save!
  end

  def process_campaign_delivery_status
    campaign_delivery.mark_status!(status: status, error_message: external_error)
  end

  def supported_status?
    %w[message-delivered message-failed].include?(params[:type])
  end

  # Relevant documentation:
  # https://dev.bandwidth.com/docs/mfa/webhooks/international/message-delivered
  # https://dev.bandwidth.com/docs/mfa/webhooks/international/message-failed
  def status
    type_mapping = {
      'message-delivered' => 'delivered',
      'message-failed' => 'failed'
    }

    type_mapping[params[:type]]
  end

  def external_error
    return nil unless error_occurred?

    error_message = params[:description]
    error_code = params[:errorCode]

    "#{error_code} - #{error_message}"
  end

  def error_occurred?
    params[:errorCode] && params[:type] == 'message-failed'
  end

  def message
    return unless params[:message][:id]

    @message ||= inbox.messages.find_by(source_id: params[:message][:id])
  end

  def campaign_delivery
    return unless params.dig(:message, :id)

    @campaign_delivery ||= CampaignDelivery.find_by(provider_message_id: params[:message][:id], inbox_id: inbox.id)
  end
end
