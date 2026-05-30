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
#  mode                   :string           default("evals"), not null
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
#  index_llm_eval_runs_one_active_live_per_account   (account_id) UNIQUE WHERE (((status)::text = ANY ((ARRAY['queued'::character varying, 'running'::character varying])::text[])) AND ((metadata ->> 'queued_llm_model_run'::text) = 'true'::text))
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (user_id => users.id)
#
class Llm::EvalRun < ApplicationRecord
  self.table_name = 'llm_eval_runs'

  SENSITIVE_FRAGMENT = /(api[_-]?key|token|secret|password|authorization|credential)(=|:)?[^\s,;&]*/i
  SENSITIVE_RESULT_KEYS = %w[
    api_key token secret password authorization credential prompt input output actual actual_output
    expected expected_output context retrieval_context messages message content response request
  ].freeze
  COMPACT_RESULT_KEYS = %i[
    status generated_at suite_count total_count passed_count failed_count error_count
  ].freeze
  COMPACT_SUITE_KEYS = %i[
    suite_id status prompt_id prompt_sha model generated_at total_count passed_count failed_count error_count pass_rate
  ].freeze
  MAX_STRING_BYTES = 2_000

  STATUSES = %w[queued running passed failed].freeze
  MODES = %w[evals].freeze

  belongs_to :account
  belongs_to :user, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :mode, inclusion: { in: MODES }
  validates :pack_ids, presence: true
  validates :requested_budget_cents, numericality: { greater_than_or_equal_to: 0 }

  scope :recent, -> { order(created_at: :desc) }

  class << self
    def sanitize_result(value)
      case value
      when Array
        value.map { |entry| sanitize_result(entry) }
      when Hash
        value.each_with_object({}) do |(key, entry), result|
          string_key = key.to_s
          result[string_key] = if SENSITIVE_RESULT_KEYS.include?(string_key)
                                 '[REDACTED]'
                               else
                                 sanitize_result(entry)
                               end
        end
      when String
        redact_string(value)
      else
        value
      end
    end

    def redact_string(value)
      redacted = value.gsub(SENSITIVE_FRAGMENT) do |match|
        key = match.split(/=|:/, 2).first
        "#{key}=[REDACTED]"
      end
      return redacted if redacted.bytesize <= MAX_STRING_BYTES

      "#{redacted[0, MAX_STRING_BYTES]}...[TRUNCATED]"
    end

    def compact_result(value)
      payload = value.is_a?(Hash) ? value : {}
      compacted = COMPACT_RESULT_KEYS.index_with { |key| value_for(payload, key) }.compact
      suites = Array(value_for(payload, :suites)).filter_map { |suite| compact_suite_result(suite) }
      compacted[:suites] = suites if suites.present?
      compacted
    end

    private

    def compact_suite_result(value)
      return unless value.is_a?(Hash)

      COMPACT_SUITE_KEYS.index_with { |key| value_for(value, key) }.compact
    end

    def value_for(payload, key)
      payload[key] || payload[key.to_s]
    end
  end

  def summary(include_result: false)
    {
      id: id,
      status: status,
      mode: mode,
      pack_ids: pack_ids,
      requested_budget_cents: requested_budget_cents,
      max_cases: max_cases,
      result_summary: result_summary,
      result: include_result ? self.class.sanitize_result(result.presence) : nil,
      error_message: error_message,
      started_at: started_at,
      finished_at: finished_at,
      created_at: created_at,
      updated_at: updated_at
    }.compact
  end

  private

  def result_summary
    suites = Array(result['suites'] || result[:suites])
    return if suites.blank?

    {
      suite_count: suites.size,
      passed_count: suites.count { |suite| suite_status(suite) == 'pass' },
      failed_count: suites.count { |suite| suite_status(suite) != 'pass' },
      suite_ids: suites.filter_map { |suite| suite['suite_id'] || suite[:suite_id] }
    }
  end

  def suite_status(suite)
    (suite['status'] || suite[:status]).to_s
  end
end
