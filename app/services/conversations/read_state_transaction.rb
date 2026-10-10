# Retries only database work whose transaction/savepoint has already rolled back.
# Read receipts and realtime delivery must stay outside this boundary.
class Conversations::ReadStateTransaction
  MAX_ATTEMPTS = 3

  def self.perform
    attempts = 0
    begin
      attempts += 1
      ActiveRecord::Base.transaction(requires_new: true) { yield }
    rescue ActiveRecord::Deadlocked
      raise if attempts >= MAX_ATTEMPTS

      retry
    end
  end
end
