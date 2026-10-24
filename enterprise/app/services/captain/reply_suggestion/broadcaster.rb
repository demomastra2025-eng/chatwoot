# frozen_string_literal: true

# The cable events of a reply suggestion. The stream is the pubsub token of the requesting user only: all the open tabs of that
# user, and nobody else. Broadcasts go through ActionCable.server.broadcast(token, { event:, data: }), the format of every
# dashboard event; from Sidekiq this works because cable uses the Redis adapter.
class Captain::ReplySuggestion::Broadcaster
  PROGRESS_EVENT = 'captain.reply_suggestion.progress'
  RESULT_EVENT = 'captain.reply_suggestion.result'

  def initialize(user:)
    @token = user&.pubsub_token
  end

  def progress(data)
    broadcast(PROGRESS_EVENT, data)
  end

  # Once per request, for every outcome (draft, no_reply, human_needed, failed, cancelled). `record` is the final request record.
  # account_id is on top level like in the progress event: the dashboard drops a cable event that has none.
  def result(record)
    broadcast(RESULT_EVENT, Captain::ReplySuggestion::StatePresenter.new(record).as_json.merge(account_id: record['account_id']))
  end

  private

  def broadcast(event, data)
    return false if @token.blank?

    ActionCable.server.broadcast(@token, { event: event, data: data })
    true
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestion] #{event} broadcast skipped: #{e.class}: #{e.message}")
    false
  end
end
