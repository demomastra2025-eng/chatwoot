# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::HandoffNaming do
  describe 'the prefixes' do
    it 'names the transfer tool transfer_to_*, falls back to agent, and still knows the former handoff_to_*' do
      expect(described_class::TOOL_PREFIX).to eq('transfer_to_')
      expect(described_class::LEGACY_TOOL_PREFIX).to eq('handoff_to_')
      expect(described_class::TOOL_PREFIXES).to eq(%w[transfer_to_ handoff_to_])
      expect(described_class::FALLBACK_PREFIX).to eq('agent')
    end

    it 'leaves room for the longest prefix inside the tool name limit' do
      expect(described_class::MAX_TARGET_NAME_LENGTH).to eq(described_class::MAX_TOOL_NAME_LENGTH - 'transfer_to_'.length)
    end
  end

  describe '.tool_name_for' do
    it 'names a colleague that has an id by it, whatever the colleague is called' do
      expect(described_class.tool_name_for('Консультант по анализам', record_id: 4)).to eq('transfer_to_agent_4')
      expect(described_class.tool_name_for('Lab consultant', record_id: 4)).to eq('transfer_to_agent_4')
    end

    it 'names an agent without an id by its normalized name' do
      expect(described_class.tool_name_for('Lab Consultant')).to eq('transfer_to_lab_consultant')
      expect(described_class.tool_name_for('scenario_35_billing_agent')).to eq('transfer_to_scenario_35_billing_agent')
    end

    it 'names an agent without an id whose name has no Latin letters by agent_ and a stable hash' do
      name = described_class.tool_name_for('Анализы')

      expect(name).to match(/\Atransfer_to_agent_[a-f0-9]{12}\z/)
      expect(described_class.tool_name_for('Анализы')).to eq(name)
      expect(described_class.tool_name_for('Запись')).not_to eq(name)
    end

    it 'keeps a long name inside the tool name limit' do
      expect(described_class.tool_name_for('a' * 200).length).to be <= described_class::MAX_TOOL_NAME_LENGTH
    end
  end

  describe '.safe_target_name' do
    it 'falls back to agent_<id> with an id and agent_<hash> without one' do
      expect(described_class.safe_target_name('Анализы', record_id: 4)).to eq('agent_4')
      expect(described_class.safe_target_name('Анализы')).to match(/\Aagent_[a-f0-9]{12}\z/)
      expect(described_class.safe_target_name('Анализы', fallback_prefix: 'assistant', record_id: 4)).to eq('assistant_4')
    end
  end

  describe 'reading a tool name that was stored' do
    it 'tells a transfer tool by either prefix and nothing else' do
      transfers = %w[transfer_to_agent_4 handoff_to_assistant_4 transfer_to_scenario_1_x_agent handoff_to_scenario_1_x_agent]
      others = ['handoff', 'plan_request', 'faq_lookup', 'manage_agent_tasks', 'transfer', 'to_handoff_to_', nil, '']

      expect(transfers.map { |name| described_class.transfer_tool_name?(name) }).to all(be(true))
      expect(others.map { |name| described_class.transfer_tool_name?(name) }).to all(be(false))
    end

    it 'gives the key of the agent a transfer tool points to, under either prefix' do
      expect(described_class.target_key_for('transfer_to_agent_4')).to eq('assistant_4')
      expect(described_class.target_key_for('handoff_to_assistant_4')).to eq('assistant_4')
      expect(described_class.target_key_for('handoff_to_agent_4')).to eq('assistant_4')
      expect(described_class.target_key_for('transfer_to_scenario_35_andalusiya_agent')).to eq('scenario_35_andalusiya_agent')
      expect(described_class.target_key_for('handoff_to_scenario_35_andalusiya_agent')).to eq('scenario_35_andalusiya_agent')
    end

    it 'gives no key for a name that is not a transfer tool or has nothing after the prefix' do
      expect([nil, '', 'handoff', 'plan_request', 'transfer_to_', 'handoff_to_'].map { |name| described_class.target_key_for(name) })
        .to all(be_nil)
    end

    it 'reads the id out of an agent key, assistant_<id> or agent_<id>' do
      expect(described_class.agent_id_from_key('assistant_12')).to eq(12)
      expect(described_class.agent_id_from_key('agent_12')).to eq(12)
      expect(['agent_', 'agent_x', 'assistant_1_2', 'scenario_3_x_agent', 'lab', nil].map { |key| described_class.agent_id_from_key(key) })
        .to all(be_nil)
    end
  end
end
