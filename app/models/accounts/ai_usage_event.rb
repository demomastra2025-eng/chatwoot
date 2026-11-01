# frozen_string_literal: true

# Durable source identities; retain entries when windows/monthly display buckets roll over.
class Accounts::AiUsageEvent < ApplicationRecord
  self.table_name = 'account_ai_usage_events'

  belongs_to :account
end
