class WhatsappWeb::RetryFailedProvisionalMessagesService
  RETRY_WINDOW = 5.minutes
  PROVISIONAL_LID_ERROR_FRAGMENT = 'provisional @lid identity'.freeze
  RETRY_ATTEMPTED_AT_KEY = 'whatsapp_web_provisional_lid_retry_attempted_at'.freeze

  pattr_initialize [:channel!, :contact!]

  def perform
    retryable_messages.each do |message|
      retry_message!(message)
    end
  end

  private

  def retryable_messages
    candidate_messages.select do |message|
      provisional_lid_failure?(message) && !retry_attempted?(message) && !superseded_message?(message)
    end
  end

  def candidate_messages
    Message
      .joins(:conversation)
      .where(
        conversations: {
          inbox_id: channel.inbox.id,
          contact_id: contact.id
        },
        inbox_id: channel.inbox.id,
        message_type: :outgoing,
        status: :failed,
        source_id: nil,
        private: false
      )
      .where('messages.created_at >= ?', RETRY_WINDOW.ago)
      .reorder(created_at: :asc)
  end

  def provisional_lid_failure?(message)
    message.external_error.to_s.include?(PROVISIONAL_LID_ERROR_FRAGMENT)
  end

  def superseded_message?(message)
    message.conversation.messages
           .where(message_type: :outgoing, private: false)
           .where('created_at > ?', message.created_at)
           .where('source_id IS NOT NULL OR status != ?', Message.statuses[:failed])
           .exists?
  end

  def retry_attempted?(message)
    (message.content_attributes || {}).with_indifferent_access[RETRY_ATTEMPTED_AT_KEY].present?
  end

  def retry_message!(message)
    Message.transaction do
      locked_message = Message.lock.find(message.id)
      return unless locked_message.failed?
      return if locked_message.source_id.present?
      return unless provisional_lid_failure?(locked_message)
      return if retry_attempted?(locked_message)
      return if locked_message.created_at < RETRY_WINDOW.ago
      return if superseded_message?(locked_message)

      locked_message.update!(
        content_attributes: (locked_message.content_attributes || {}).merge(
          RETRY_ATTEMPTED_AT_KEY => Time.current.iso8601
        )
      )
      Messages::StatusUpdateService.new(locked_message, 'sent').perform
      SendReplyJob.perform_later(locked_message.id)
    end
  end
end
