# frozen_string_literal: true

require 'json'
require 'securerandom'

# The state of a reply suggestion request, in Redis (TTL 30 minutes, like the approval cards of a suggestion).
#
# One writer: StartService creates the record, the job (GenerateJob) is the only one that changes it afterwards. The cancel flag,
# the consumed flag and the progress snapshot are separate keys, so no endpoint ever rewrites the main record (no lost updates).
module Captain::ReplySuggestion::RequestStore
  PREFIX = 'captain:reply_suggestion'
  ACTIVE_STATUSES = %w[queued running].freeze
  TERMINAL_STATUSES = %w[draft no_reply human_needed failed cancelled].freeze

  class << self
    def new_id
      SecureRandom.uuid
    end

    def create!(attributes)
      now = Time.current.utc.iso8601(3)
      record = {
        'id' => new_id, 'status' => 'queued', 'reason_code' => nil, 'created_at' => now, 'started_at' => nil, 'finished_at' => nil,
        'deadline_at' => nil, 'duration_ms' => nil, 'budget_seconds' => Captain::ReplySuggestion.budget_seconds,
        'result' => nil
      }.merge(attributes.stringify_keys)
      write!(record)
      Redis::Alfred.set(latest_key(record['account_id'], record['user_id'], record['conversation_id']), record['id'],
                        ex: Captain::ReplySuggestion::TTL_SECONDS)
      record
    end

    # The raw record, as the job wrote it.
    def fetch_raw(id)
      return if id.blank?

      raw = Redis::Alfred.get(key(id))
      return if raw.blank?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # The record as the manager sees it: a lost job does not leave the UI hanging (the view is not written back).
    def fetch(id, now: Time.current)
      record = fetch_raw(id)
      return if record.nil?

      view = Captain::ReplySuggestion::RequestView.apply(record, now: now)
      view['progress'] = read_progress(id) if ACTIVE_STATUSES.include?(view['status'])
      view
    end

    def latest_id(account_id, user_id, conversation_id)
      Redis::Alfred.get(latest_key(account_id, user_id, conversation_id)).presence
    end

    # The job is the only writer: it holds the record it read, changes it and writes it back (the record may have expired meanwhile).
    def mark_running!(record, started_at:, deadline_at:)
      write!(record.merge('status' => 'running', 'started_at' => started_at.utc.iso8601(3), 'deadline_at' => deadline_at.utc.iso8601(3)))
    end

    # The router gave the run the budget of one agent (RunControl#shorten!): the real deadline and budget of the run.
    def reschedule!(record, deadline_at:, budget_seconds:)
      write!(record.merge('deadline_at' => deadline_at.utc.iso8601(3), 'budget_seconds' => budget_seconds.to_i))
    end

    def finish!(record, status:, result: nil, reason_code: nil, duration_ms: nil)
      write!(
        record.merge(
          'status' => status.to_s, 'result' => result, 'reason_code' => reason_code, 'duration_ms' => duration_ms,
          'finished_at' => Time.current.utc.iso8601(3)
        )
      )
    end

    # Throttled by the caller (TraceCollector). A separate key: the job also rewrites the main record.
    def write_progress(id, data)
      Redis::Alfred.set(progress_key(id), JSON.generate(data), ex: Captain::ReplySuggestion::TTL_SECONDS)
    rescue StandardError => e
      Rails.logger.debug { "[CAPTAIN][ReplySuggestion] progress snapshot skipped: #{e.message}" }
    end

    def read_progress(id)
      raw = Redis::Alfred.get(progress_key(id))
      raw.present? ? JSON.parse(raw) : nil
    rescue JSON::ParserError
      nil
    end

    def request_cancel!(id)
      Redis::Alfred.set(cancel_key(id), '1', ex: Captain::ReplySuggestion::TTL_SECONDS)
    end

    def cancel_requested?(id)
      Redis::Alfred.exists?(cancel_key(id))
    end

    # The manager acted on the suggestion (inserted, dismissed, cancelled): it never reappears on return.
    def consume!(id)
      Redis::Alfred.set(consumed_key(id), Time.current.utc.iso8601, ex: Captain::ReplySuggestion::TTL_SECONDS)
    end

    def consumed?(id)
      Redis::Alfred.exists?(consumed_key(id))
    end

    def key(id) = "#{PREFIX}:req:#{id}"
    def progress_key(id) = "#{PREFIX}:progress:#{id}"
    def cancel_key(id) = "#{PREFIX}:cancel:#{id}"
    def consumed_key(id) = "#{PREFIX}:consumed:#{id}"
    def latest_key(account_id, user_id, conversation_id) = "#{PREFIX}:latest:#{account_id}:#{user_id}:#{conversation_id}"

    private

    def write!(record)
      Redis::Alfred.set(key(record['id']), JSON.generate(record), ex: Captain::ReplySuggestion::TTL_SECONDS)
      record
    end
  end
end
