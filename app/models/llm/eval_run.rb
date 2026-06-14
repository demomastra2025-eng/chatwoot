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
    status generated_at suite_count total_count passed_count failed_count error_count pass_rate duration_ms estimated_cost
  ].freeze
  COMPACT_SUITE_KEYS = %i[
    suite_id status prompt_id prompt_sha model generated_at total_count passed_count failed_count error_count pass_rate duration_ms
  ].freeze
  COMPACT_CASE_KEYS = %i[id description tags status duration_ms failures].freeze
  COMPACT_FAILED_SCENARIO_KEYS = %i[suite_id id description tags status duration_ms failures].freeze
  COMPACT_ARTIFACT_KEYS = %i[case_id status failures usage].freeze
  COMPACT_TIMELINE_KEYS = %i[index type role tool_name action status duration_ms].freeze
  COMPACT_TRACE_DIGEST_KEYS = %i[
    total_count included_count counts_by_event_name tool_names error_count schema_invalid_count openrouter_generation_ids token_totals
    estimated_cost
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
      failed_scenarios = compact_failed_scenarios(value_for(payload, :failed_scenarios))
      compacted[:failed_scenarios] = failed_scenarios if failed_scenarios.present?
      suites = Array(value_for(payload, :suites)).filter_map { |suite| compact_suite_result(suite) }
      compacted[:suites] = suites if suites.present?
      compacted
    end

    private

    def compact_suite_result(value)
      return unless value.is_a?(Hash)

      compacted = COMPACT_SUITE_KEYS.index_with { |key| value_for(value, key) }.compact
      case_summaries = compact_case_summaries(value)
      compacted[:case_summaries] = case_summaries if case_summaries.present?
      compacted
    end

    def compact_case_result(value)
      return unless value.is_a?(Hash)

      compacted = COMPACT_CASE_KEYS.index_with { |key| sanitize_result(value_for(value, key)) }.compact
      artifact = compact_artifact(value_for(value, :artifact))
      compacted[:artifact] = artifact if artifact.present?
      compacted
    end

    def compact_failed_scenarios(value)
      Array(value).filter_map do |scenario|
        next unless scenario.is_a?(Hash)

        COMPACT_FAILED_SCENARIO_KEYS.index_with { |key| sanitize_result(value_for(scenario, key)) }.compact
      end
    end

    def compact_artifact(value)
      return unless value.is_a?(Hash)

      compacted = COMPACT_ARTIFACT_KEYS.index_with { |key| sanitize_result(value_for(value, key)) }.compact
      timeline = compact_artifact_timeline(value_for(value, :timeline))
      trace_digest = compact_trace_digest(value_for(value, :trace_digest))
      compacted[:timeline] = timeline if timeline.present?
      compacted[:trace_digest] = trace_digest if trace_digest.present?
      compacted
    end

    def compact_artifact_timeline(value)
      Array(value).filter_map do |entry|
        next unless entry.is_a?(Hash)

        COMPACT_TIMELINE_KEYS.index_with { |key| sanitize_result(value_for(entry, key)) }.compact
      end
    end

    def compact_trace_digest(value)
      return unless value.is_a?(Hash)

      COMPACT_TRACE_DIGEST_KEYS.index_with { |key| sanitize_result(value_for(value, key)) }.compact
    end

    def existing_case_summaries(value)
      Array(value_for(value, :case_summaries)).filter_map do |case_summary|
        compact_case_result(case_summary)
      end
    end

    def compact_case_summaries(value)
      existing_case_summaries(value).presence ||
        Array(value_for(value, :cases)).filter_map { |case_result| compact_case_result(case_result) }
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
      result: include_result ? self.class.sanitize_result(self.class.compact_result(result.presence)) : nil,
      error_message: error_message,
      started_at: started_at,
      finished_at: finished_at,
      created_at: created_at,
      updated_at: updated_at
    }.compact
  end

  private

  def result_summary
    suites = result_suites
    return if suites.blank?

    {
      suite_count: suites.size,
      total_count: result_value(:total_count),
      passed_count: result_value(:passed_count) || passed_suite_count(suites),
      failed_count: result_value(:failed_count) || failed_suite_count(suites),
      error_count: result_value(:error_count),
      pass_rate: result_value(:pass_rate),
      duration_ms: result_value(:duration_ms),
      estimated_cost: result_value(:estimated_cost),
      suite_ids: suites.filter_map { |suite| value_for_suite(suite, :suite_id) }
    }.compact
  end

  def result_suites
    Array(result_value(:suites))
  end

  def result_value(key)
    result[key.to_s] || result[key]
  end

  def passed_suite_count(suites)
    suites.count { |suite| suite_status(suite) == 'pass' }
  end

  def failed_suite_count(suites)
    suites.count { |suite| suite_status(suite) != 'pass' }
  end

  def suite_status(suite)
    value_for_suite(suite, :status).to_s
  end

  def value_for_suite(suite, key)
    suite[key.to_s] || suite[key]
  end
end
