# frozen_string_literal: true

# The request record (RequestStore) as the manager's UI reads it: SuggestionState. It is the only shape the UI reads, in the POST
# answer, in the GET answer and in the `captain.reply_suggestion.result` cable event.
class Captain::ReplySuggestion::StatePresenter
  class << self
    # New customer messages arrived after the suggestion was requested.
    def stale?(record)
      based_on = record['based_on_message_id']
      return false if based_on.blank? || record['conversation_id'].blank?

      Message.where(conversation_id: record['conversation_id'], message_type: :incoming, private: false).exists?(['id > ?', based_on])
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
