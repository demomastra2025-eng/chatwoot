# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::Review do
  let(:scorer) { Captain::Evals::RoutingBenchmark::Scorer }

  def hint(id, detail = nil)
    { 'id' => id, 'check' => scorer.base_check(id), 'severity' => scorer.severity_for(id), 'gate' => scorer.gate_item_for(id), 'detail' => detail }.compact
  end

  def turn(dialogue, number, hints: [], **extra)
    { 'fixture' => '/set/ws_mid__kazakh_mixed_01.yml', 'dialogue' => dialogue, 'run' => 1, 'turn' => number, 'customer' => 'ок', 'patient_text' => 'Готово.',
      'acting_agent' => 'Запись к врачу', 'hints' => hints }.merge(extra.stringify_keys)
  end

  describe '.records' do
    it 'lists every hit of a hint with its detail, the words of the patient, the reply and the verdict of the judge' do
      judge = { 'pass' => false, 'reason' => 'no booking in the database' }
      cases = [turn('d_01', 2, hints: [hint('false_success_claim', 'claims book; successful tools: none')], judge: judge)]

      expect(described_class.records(cases)).to eq([{
        'fixture' => 'ws_mid__kazakh_mixed_01.yml', 'dialogue' => 'd_01', 'run' => 1, 'turn' => 2, 'check' => 'false_success_claim', 'severity' => 'critical',
        'gate' => 'b', 'detail' => 'claims book; successful tools: none', 'patient_message' => 'ок', 'agent_reply' => 'Готово.',
        'acting_agent' => 'Запись к врачу', 'judge' => judge
      }])
    end

    it 'puts the critical hints first, then the others in the order of the dialogue' do
      cases = [turn('b_01', 1, hints: [hint('greeting_only_reply')]), turn('a_01', 4, hints: [hint('wrong_language'), hint('reply_leak:latin')]),
               turn('a_01', 2, hints: [hint('foreign_patient_data')])]

      expect(described_class.records(cases).map { |record| [record['dialogue'], record['turn'], record['check']] }).to eq(
        [['a_01', 2, 'foreign_patient_data'], ['a_01', 4, 'reply_leak:latin'], ['a_01', 4, 'wrong_language'], ['b_01', 1, 'greeting_only_reply']]
      )
    end

    it 'has nothing for a run without hints' do
      expect(described_class.records([turn('d_01', 1)])).to eq([])
    end

    it 'reads the hits that an older report holds as failures of the turn, and leaves the facts out' do
      older = turn('d_01', 1).except('hints').merge('failures' => [hint('wrong_agent', 'acted: nil'), hint('reply_leak:stock_text', 'Запрос отменён.')],
                                                    'reasons' => %w[wrong_agent reply_leak:stock_text])
      reasons_only = turn('d_02', 1).except('hints').merge('reasons' => %w[false_handoff_claim missing_tool:handoff])

      expect(described_class.records([older, reasons_only]).map { |record| [record['dialogue'], record['check'], record['severity']] }).to eq(
        [['d_01', 'reply_leak:stock_text', 'critical'], ['d_02', 'false_handoff_claim', 'critical']]
      )
    end

    it 'reads symbol keys, as a run builds its cases' do
      case_with_symbols = turn('d_01', 1, hints: [hint('wrong_language', 'expected kk')]).deep_symbolize_keys

      expect(described_class.records([case_with_symbols]).first).to include('check' => 'wrong_language', 'severity' => 'important')
    end
  end
end