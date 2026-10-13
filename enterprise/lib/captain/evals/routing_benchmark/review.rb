# frozen_string_literal: true

# The `needs_review` list of a benchmark run: the hits of the checks that read text (Scorer::HINT_CHECKS), for a person to read. A
# detector of text can be wrong, so a hit never fails a turn or the gate (owner decision 2A); the rubric judge saw each hit in its
# evidence and decided by meaning, and the list shows its verdict next to the hit. Critical hints come first: a claim of an action
# that no tool result shows, internal material or another patient's data in the reply, a request for a person without a handoff.
#
# A report of an older run holds these hits as failures of the turn; they are read as hints here, so the same list can be rebuilt from it.
class Captain::Evals::RoutingBenchmark::Review
  MESSAGE_LIMIT = 400
  REPLY_LIMIT = 700

  class << self
    # The hints of a case (a hash with string keys): the stored list, else the failures of an older report that are hint checks.
    def hints_of(item)
      scorer = Captain::Evals::RoutingBenchmark::Scorer
      return Array(item['hints']).map { |hint| hint.to_h.deep_stringify_keys } if item['hints'].is_a?(Array)

      failures = if item['failures'].is_a?(Array)
                   item['failures']
                 else
                   Array(item['reasons']).map do |reason|
                     { 'id' => reason, 'severity' => scorer.severity_for(reason), 'gate' => scorer.gate_item_for(reason) }
                   end
                 end
      failures.select { |failure| scorer.hint?(failure['id']) }
    end

    # One record per hit of the cases (string-keyed hashes), critical first.
    def records(cases)
      list = cases.flat_map { |item| hints_of(item.to_h.deep_stringify_keys).map { |hint| record(item.to_h.deep_stringify_keys, hint) } }
      list.sort_by do |record|
        [Captain::Evals::RoutingBenchmark::Triage.severity_rank(record['severity']), record['fixture'], record['dialogue'], record['run'].to_i,
         record['turn'].to_i, record['check']]
      end
    end

    private

    def record(item, hint)
      {
        'fixture' => File.basename(item['fixture'].to_s), 'dialogue' => item['dialogue'], 'run' => item['run'], 'turn' => item['turn'],
        'check' => hint['id'], 'severity' => hint['severity'] || Captain::Evals::RoutingBenchmark::Scorer.severity_for(hint['id']),
        'gate' => hint['gate'], 'detail' => hint['detail'],
        'patient_message' => item['customer'].to_s.squish.truncate(MESSAGE_LIMIT),
        'agent_reply' => (item['patient_text'] || item['reply']).to_s.squish.truncate(REPLY_LIMIT),
        'acting_agent' => item['acting_agent'], 'judge' => item['judge']
      }.compact
    end
  end
end
