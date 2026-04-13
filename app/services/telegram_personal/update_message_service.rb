class TelegramPersonal::UpdateMessageService
  pattr_initialize [:inbox!, :params!]

  def perform
    message = find_message
    return if message.blank?

    message.update!(
      content: params[:text].presence || params[:caption].presence || message.content,
      content_attributes: (message.content_attributes || {}).merge(updated_content_attributes)
    )
  end

  private

  def updated_content_attributes
    {}.tap do |attrs|
      attrs[:edited] = true if params[:text].present? || params[:caption].present?
      attrs[:telegram_reactions] = params[:reactions].to_h if params.key?(:reactions)
      attrs[:telegram_forwarded_from] = params[:forwarded_from].to_h if params[:forwarded_from].present?
    end
  end

  def find_message
    message_id = params[:message_id].to_s
    return if message_id.blank?

    inbox.messages.find_by(source_id: message_id) ||
      inbox.messages.find_each.find do |message|
        Array.wrap(message.content_attributes&.dig('telegram_message_ids')).map(&:to_s).include?(message_id)
      end
  end
end
