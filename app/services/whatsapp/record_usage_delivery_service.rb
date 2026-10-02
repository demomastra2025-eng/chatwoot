class Whatsapp::RecordUsageDeliveryService
  pattr_initialize [:inbox!, :message!, :status!]

  def perform
    return unless eligible_delivery?

    WhatsappUsageDelivery.record_delivery!(inbox: inbox, message: message, status: status)
  end

  private

  def eligible_delivery?
    inbox.whatsapp_cloud_channel? &&
      %w[delivered read].include?(status[:status].to_s) &&
      trackable_message? &&
      matching_provider_message?
  end

  def matching_provider_message?
    status[:id].present? &&
      message.source_id.present? &&
      message.account_id == inbox.account_id &&
      message.inbox_id == inbox.id &&
      status[:id].to_s == message.source_id.to_s
  end

  def trackable_message?
    return false if message.private?
    return false unless message.outgoing? || message.template?

    attributes = message.content_attributes.to_h.with_indifferent_access
    boolean = ActiveModel::Type::Boolean.new
    return false if boolean.cast(attributes[:external_echo])
    return false if boolean.cast(attributes[:imported_history])
    return false if boolean.cast(attributes[:whatsapp_history_import])

    true
  end
end
