class VkCommunity::UpdateMessageService
  pattr_initialize [:inbox!, :params!]

  def perform
    payload = params.dig(:object, :message).to_h.deep_symbolize_keys
    message = inbox.messages.find_by(source_id: payload[:id].to_s)
    return if message.blank?

    message.update!(
      content: payload[:text].to_s,
      content_attributes: (message.content_attributes || {}).merge(edited: true)
    )
  end
end
