class CaptainListener < BaseListener
  include ::Events::Types

  def conversation_resolved(event)
    conversation = extract_conversation_and_account(event)[0]
    return unless conversation.inbox.captain_active?

    assistant = Captain::Conversation::AgentOwnership.new(conversation: conversation).current_assistant
    return unless assistant

    return unless Captain::AccountSettings.new(conversation.account).section('faq')['generate_from_resolved']

    Captain::Llm::ConversationFaqService.new(assistant, conversation).generate_and_deduplicate
  end
end
