# Posts the public text for a handoff that the system applies because Captain
# could not answer by itself (quota used up, no valid reply, an unfinished
# conversation). It is only the assistant's own handoff message and only while
# that message is enabled; in AI mode a text generated for this handoff comes
# first. There is no built-in wording, so an assistant without a configured
# message hands off without public text.
class Captain::SystemHandoffMessageService
  pattr_initialize [:conversation!, :assistant!, { generated_message: nil }]

  def perform
    I18n.with_locale(conversation.account.locale) do
      text = content
      next if text.blank?

      conversation.messages.create!(
        message_type: :outgoing,
        account_id: conversation.account_id,
        inbox_id: conversation.inbox_id,
        sender: assistant,
        content: assistant.render_runtime_text(text, conversation: conversation),
        preserve_waiting_since: true
      )
    end
  end

  def content
    return unless assistant.handoff_message_enabled?

    generated = generated_message.to_s.strip.presence if assistant.handoff_message_mode_value == Captain::Assistant::MESSAGE_MODE_AI
    generated || assistant.config['handoff_message'].to_s.strip.presence
  end
end
