# frozen_string_literal: true

# The view of a request record that keeps the dashboard from hanging on a lost job (it is not written back):
#
#   queued, waited in the queue longer than allowed (+30 s)         failed{queue_timeout}
#   running, past its deadline and the safety net (+30 s)           failed{interrupted}
#   queued or running with the cancel flag set                      cancelled
module Captain::ReplySuggestion::RequestView
  class << self
    def apply(record, now:)
      status = record['status']
      return record unless Captain::ReplySuggestion::RequestStore::ACTIVE_STATUSES.include?(status)

      return record.merge(failed('queue_timeout', now)) if status == 'queued' && queue_lost?(record, now)
      return record.merge(failed('interrupted', now)) if status == 'running' && run_lost?(record, now)
      return record.merge('status' => 'cancelled', 'result' => nil, 'finished_at' => stamp(now)) if cancelled?(record)

      record
    end

    private

    def cancelled?(record)
      Captain::ReplySuggestion::RequestStore.cancel_requested?(record['id'])
    end

    def failed(reason_code, now)
      { 'status' => 'failed', 'reason_code' => reason_code, 'result' => { 'reason_code' => reason_code }, 'finished_at' => stamp(now) }
    end

    def stamp(now)
      now.utc.iso8601(3)
    end

    def queue_lost?(record, now)
      now - Time.zone.parse(record['created_at']) > Captain::ReplySuggestion::MAX_QUEUE_WAIT_SECONDS + 30
    end

    def run_lost?(record, now)
      deadline = record['deadline_at'].presence && Time.zone.parse(record['deadline_at'])
      return false unless deadline

      now > deadline + Captain::ReplySuggestion::HARD_GRACE_SECONDS + 30
    end
  end
end
