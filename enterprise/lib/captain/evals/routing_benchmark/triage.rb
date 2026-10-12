# frozen_string_literal: true

require 'json'

# The triage list of a benchmark run: one record per failed check, with everything a person needs to decide whether
# the failure is an agent bug, a test bug (fixture or detector) or a judge error, and an empty `triage` field to write
# that decision into. A decided list is passed back as TRIAGE=<report.json> to the next run or to the gate task, so a
# failure that was signed as a test bug is not asked about twice.
class Captain::Evals::RoutingBenchmark::Triage
  LABELS = %w[agent_bug test_bug judge_error].freeze
  # Labels that take a failure out of the overall score: the agent did nothing wrong.
  NOT_AGENT = %w[test_bug judge_error].freeze
  MESSAGE_LIMIT = 400
  REPLY_LIMIT = 700

  class << self
    # Identifies a failed check across runs: the same dialogue, turn and check in another run is the same failure.
    def key(fixture, dialogue, turn, check)
      [File.basename(fixture.to_s), dialogue, turn, check].join('|')
    end

    # { key => label } from a report whose triage records were filled in, or from { "labels" => { key => label } }.
    def load(path)
      return {} if path.blank?

      data = JSON.parse(File.read(path))
      records = data.is_a?(Hash) ? (data['triage'] || data['records']) : data
      labels = data.is_a?(Hash) && data['labels'].is_a?(Hash) ? data['labels'].to_h : {}
      Array(records).each do |record|
        label = record['triage'].to_s
        labels[key(record['fixture'], record['dialogue'], record['turn'], record['check'])] = label if LABELS.include?(label)
      end
      labels
    end

    # One record per failed check of the cases (string-keyed hashes), critical first.
    def records(cases, labels: {})
      list = cases.flat_map { |item| item_records(item, labels) }
      list.sort_by do |record|
        [severity_rank(record['severity']), record['fixture'], record['dialogue'], record['run'].to_i, record['turn'].to_i, record['check']]
      end
    end

    def severity_rank(severity) = Captain::Evals::RoutingBenchmark::Scorer::SEVERITIES.index(severity.to_s) || 99

    # The failures of a case as hashes with id, severity, gate and detail; older reports hold only the reasons.
    def failures_of(item)
      return item['failures'] if item['failures'].is_a?(Array)

      scorer = Captain::Evals::RoutingBenchmark::Scorer
      Array(item['reasons']).map do |reason|
        { 'id' => reason, 'check' => scorer.base_check(reason), 'severity' => scorer.severity_for(reason), 'gate' => scorer.gate_item_for(reason) }
      end
    end

    private

    def item_records(item, labels)
      failures_of(item).map do |failure|
        fixture = File.basename(item['fixture'].to_s)
        label = labels[key(fixture, item['dialogue'], item['turn'], failure['id'])]
        {
          'fixture' => fixture, 'dialogue' => item['dialogue'], 'run' => item['run'], 'turn' => item['turn'],
          'check' => failure['id'], 'severity' => failure['severity'], 'gate' => failure['gate'], 'detail' => failure['detail'],
          'patient_message' => item['customer'].to_s.squish.truncate(MESSAGE_LIMIT),
          'agent_reply' => (item['patient_text'] || item['reply']).to_s.squish.truncate(REPLY_LIMIT),
          'acting_agent' => item['acting_agent'], 'tool_calls' => tool_calls(item), 'expectation' => item['expectation'],
          'db_delta' => item['db_delta']
        }.compact.merge('triage' => label)
      end
    end

    def tool_calls(item)
      return item['tool_calls'] if item['tool_calls'].present?

      Array(item['tool_steps']).map { |step| { 'tool' => step.to_s.split(':').first, 'success' => step.to_s.split(':')[1] == 'true' } }
    end
  end
end
