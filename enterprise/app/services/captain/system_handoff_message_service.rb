# Posts the public text for a handoff that the system applies because Captain
# could not answer by itself (quota used up, no valid reply, an unfinished
# conversation). The text comes from Captain::CustomerNoticeService: nothing
# while the workspace handoff message is disabled or has no text, the fixed
# text, or, in AI mode, a text written by the separate notice model (with the
# fixed text, then a neutral sentence, as the fallback). The model can take
# seconds, so a caller that holds a lock asks #prepare first and calls #perform
# inside the lock. A caller that must not wait for a model (the incoming message
# of a customer whose Captain quota is used up) passes generate: false and gets
# the fallback text at once.
class Captain::SystemHandoffMessageService
  def initialize(conversation:, assistant:, reason_label: nil, generate: true)
    @conversation = conversation
    @assistant = assistant
    @reason_label = reason_label
    @generate = generate
  end

  # Writes the notice text now (at most one model call per service object) and returns self.
  def prepare
    content
    self
  end

  def perform
    text = content
    return if text.blank?

    I18n.with_locale(conversation.account.locale) do
      conversation.messages.create!(
        message_type: :outgoing,
        account_id: conversation.account_id,
        inbox_id: conversation.inbox_id,
        sender: assistant,
        content: text,
        preserve_waiting_since: true
      )
    end
  end

  def content
    notice.text
  end

  def notice
    @notice ||= Captain::CustomerNoticeService.new(
      conversation: conversation, assistant: assistant, kind: :handoff, reason_label: reason_label, generate: generate
    )
  end

  private

  attr_reader :conversation, :assistant, :reason_label, :generate
end
