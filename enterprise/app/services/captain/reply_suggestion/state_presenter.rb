# frozen_string_literal: true

# The request record (RequestStore) as the manager's UI reads it: SuggestionState. It is the only shape the UI reads, in the POST
# answer, in the GET answer and in the `captain.reply_suggestion.result` cable event.
class Captain::ReplySuggestion::StatePresenter
  class << self
    # New customer messages arrived after the suggestion was requested, in any conversation of the person.
    def stale?(record)
      based_on = record['based_on_message_id']
      return false if based_on.blank? || record['conversation_id'].blank?

      conversation = Conversation.find_by(id: record['conversation_id'])
      return false unless conversation

      customer_messages(conversation).exists?(['messages.id > ?', based_on])
    end

    # The public messages of the customer over the whole person: every conversation of the communication thread, as the history
    # of the suggestion reads them (Captain::Conversation::ControlService.messages_scope, see HistoryBuilder). A message that came
    # to another channel of the same person also makes a suggestion stale and moves the message it is based on.
    def customer_messages(conversation)
      Captain::Conversation::ControlService.messages_scope(conversation).where(message_type: :incoming, private: false)
    end
  end

  def initialize(record, reused: nil)
    @record = record
    @reused = reused
  end

  def as_json(*)
    payload = {
      suggestion_request_id: @record['id'],
      status: status,
      engine: @record['engine'],
      conversation_id: @record['conversation_display_id'],
      conversation_record_id: @record['conversation_id'],
      created_at: @record['created_at'],
      started_at: @record['started_at'],
      finished_at: @record['finished_at'],
      deadline_at: @record['deadline_at'],
      budget_seconds: @record['budget_seconds'],
      duration_ms: @record['duration_ms'],
      stale: self.class.stale?(@record),
      progress: active? ? @record['progress'] : nil,
      result: result
    }
    # Only the POST answer has it.
    payload[:reused] = @reused unless @reused.nil?
    payload
  end

  private

  def status
    @record['status']
  end

  def active?
    Captain::ReplySuggestion::RequestStore::ACTIVE_STATUSES.include?(status)
  end

  # null while queued, running and cancelled.
  def result
    return if active? || status == 'cancelled'

    @record['result']
  end
end
