class Captain::Labels::AutoTagConversationJob < ApplicationJob
  queue_as :low

  def perform(conversation_id, trigger_message_id: nil)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.blank?
    return unless Captain::Labels::SmartTaggingService.enabled_for_account?(conversation.account)

    if trigger_message_id.present?
      newer_incoming_exists = conversation.messages
                                          .incoming
                                          .where(private: false)
                                          .where('id > ?', trigger_message_id)
                                          .exists?
      return if newer_incoming_exists
    end

    Captain::Labels::SmartTaggingService.new(conversation: conversation).perform
  end
end
