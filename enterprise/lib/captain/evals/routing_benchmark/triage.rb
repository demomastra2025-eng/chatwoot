# frozen_string_literal: true

require 'digest'
require 'json'

# The triage list of a benchmark run: one record per failed check, with everything a person needs to decide whether
# the failure is an agent bug, a test bug (fixture or detector) or a judge error, and an empty `triage` field to write
# that decision into. A decided list is passed back as TRIAGE=<report.json> to the next run or to the gate task, so a
# failure that was signed as a test bug is not asked about twice.
#
# A decision belongs to one failure, not to a place in a dialogue: a record carries a `signature` (a digest of the check
# detail and of the database changes of the turn, with record ids left out) and a label applies only to a failure with
# the same signature. When the same check fails on the same turn in another way, it is a new failure and asks again. A
# label without a signature (an older report, or a `labels` object written by hand) applies to every failure of that check
# on that turn.
class Captain::Evals::RoutingBenchmark::Triage
  LABELS = %w[agent_bug test_bug judge_error].freeze
  # Labels that take a failure out of the overall score: the agent did nothing wrong.
  NOT_AGENT = %w[test_bug judge_error].freeze
  MESSAGE_LIMIT = 400
  REPLY_LIMIT = 700
  # A number that is a record id (not a time, a date or a part of one) in a check detail: "appointment 12", "ids 3 and 4".
  RECORD_ID = /(?<![\d:T.\-])\d{1,9}(?![\d:.\-])/
  APPOINTMENT_IDS = /(\bappointment(?:s|\(s\))?\s+)\d+(?:(?:,\s*|\s+and\s+)\d+)*/

  class << self
    # Identifies a failed check across runs: the same dialogue, turn and check in another run is the same failure when
    # the signature is the same too.
    def key(fixture, dialogue, turn, check, signature = nil)
      [File.basename(fixture.to_s), dialogue, turn, check, signature].compact.join('|')
    end

    # A short digest of what the failure was: the detail of the check and the database changes of the turn, both without
    # record ids, which differ from run to run.
    def signature(item, failure)
      basis = JSON.generate([failure['id'], without_record_ids(failure['detail']), delta_basis(item['db_delta'])])
      Digest::SHA1.hexdigest(basis).first(8)
    end

    # The decision for a failure: a label of its own signature, else a label given for the check on that turn.
    def label_for(labels, item, failure)
      fixture, dialogue, turn = item['fixture'], item['dialogue'], item['turn']
      labels[key(fixture, dialogue, turn, failure['id'], signature(item, failure))] || labels[key(fixture, dialogue, turn, failure['id'])]
    end

    # { key => label } from a report whose triage records were filled in, or from { "labels" => { key => label } }.
    def load(path)
      return {} if path.blank?

      labels_from(JSON.parse(File.read(path)))
    end

    def labels_from(data)
      records = data.is_a?(Hash) ? (data['triage'] || data['records']) : data
      labels = data.is_a?(Hash) && data['labels'].is_a?(Hash) ? data['labels'].to_h : {}
      Array(records).each do |record|
        label = record['triage'].to_s
        labels[key(record['fixture'], record['dialogue'], record['turn'], record['check'], record['signature'])] = label if LABELS.include?(label)
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
        {
          'fixture' => fixture, 'dialogue' => item['dialogue'], 'run' => item['run'], 'turn' => item['turn'],
          'check' => failure['id'], 'severity' => failure['severity'], 'gate' => failure['gate'], 'detail' => failure['detail'],
          'signature' => signature(item, failure),
          'patient_message' => item['customer'].to_s.squish.truncate(MESSAGE_LIMIT),
          'agent_reply' => (item['patient_text'] || item['reply']).to_s.squish.truncate(REPLY_LIMIT),
          'acting_agent' => item['acting_agent'], 'tool_calls' => tool_calls(item), 'expectation' => item['expectation'],
          'db_delta' => item['db_delta'], 'transfers' => item.dig('evidence', 'transfers'), 'council' => item.dig('evidence', 'council'),
          'silent_handoff' => item['silent_handoff'], 'warnings' => item['warnings'].presence
        }.compact.merge('triage' => label_for(labels, item, failure))
      end
    end

    def tool_calls(item)
      return item['tool_calls'] if item['tool_calls'].present?

      Array(item['tool_steps']).map { |step| { 'tool' => step.to_s.split(':').first, 'success' => step.to_s.split(':')[1] == 'true' } }
    end

    # The changes of the turn as the report shows them, without the ids of the rows.
    def delta_basis(delta)
      Array(delta).map { |row| row.to_h.deep_stringify_keys.except('id') }
    end

    def without_record_ids(detail)
      detail.to_s.gsub(APPOINTMENT_IDS, '\1#').gsub(RECORD_ID, '#').squish
    end
  end
end
