# frozen_string_literal: true

# == Schema Information
#
# Table name: llm_eval_runs
#
#  id                     :bigint           not null, primary key
#  error_message          :text
#  finished_at            :datetime
#  max_cases              :integer
#  metadata               :jsonb            not null
#  mode                   :string           default("live_model"), not null
#  pack_ids               :jsonb            not null
#  requested_budget_cents :integer          default(0), not null
#  result                 :jsonb            not null
#  started_at             :datetime
#  status                 :string           default("queued"), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#  user_id                :bigint
#
# Indexes
#
#  index_llm_eval_runs_on_account_id                 (account_id)
#  index_llm_eval_runs_on_account_id_and_created_at  (account_id,created_at)
#  index_llm_eval_runs_on_account_id_and_status      (account_id,status)
#  index_llm_eval_runs_on_user_id                    (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (user_id => users.id)
#
class Llm::EvalRun < ApplicationRecord
  self.table_name = 'llm_eval_runs'

  STATUSES = %w[queued running passed failed].freeze
  MODES = %w[live_model].freeze

  belongs_to :account
  belongs_to :user, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :mode, inclusion: { in: MODES }
  validates :pack_ids, presence: true
  validates :requested_budget_cents, numericality: { greater_than_or_equal_to: 0 }

  scope :recent, -> { order(created_at: :desc) }

  def summary
    {
      id: id,
      status: status,
      mode: mode,
      pack_ids: pack_ids,
      requested_budget_cents: requested_budget_cents,
      max_cases: max_cases,
      result: result.presence,
      error_message: error_message,
      started_at: started_at,
      finished_at: finished_at,
      created_at: created_at,
      updated_at: updated_at
    }.compact
  end
end
