# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::ToolTrace do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:event_class) { Struct.new(:event_name, :tool_name, :payload) }

  before { account.enable_features!('audit_logs') }

  # What BasePublicTool does after it ran a tool.
  def audit(tool, arguments:, result:)
    Captain::ToolExecutionAuditService.record(
      assistant: assistant, scope_name: Captain::ToolAccess::SCOPE_AGENT, tool_definition: { id: tool, title: tool.humanize },
      arguments: arguments, result: result, runtime_context: { conversation_id: 1, current_agent: 'Запись к врачу' }
    )
  end

  def event(tool, success: true)
    event_class.new('llm.tool.complete', tool, { 'result_success' => success })
  end

  describe 'audit rows' do
    it 'are written for the executed public tools of an account with audit_logs, which is how the benchmark sees arguments' do
      audit('create_appointment', arguments: { resource_id: 4, starts_at: '2026-10-15T12:00' },
                                  result: JSON.generate(success: true, status: 'created'))

      row = Enterprise::AuditLog.find_by!(associated_type: 'Account', associated_id: account.id, action: 'captain_tool_execute')

      expect(row.audited_changes).to include('tool_id' => 'create_appointment', 'arguments' => { 'resource_id' => 4, 'starts_at' => '2026-10-15T12:00' },
                                             'result_success' => true, 'current_agent' => 'Запись к врачу')
    end

    it 'are read after a cursor, so a turn sees only its own' do
      audit('faq_lookup', arguments: { query: 'часы' }, result: 'ok')
      cursor = described_class.cursor(account)
      audit('create_appointment', arguments: { resource_id: 4 }, result: JSON.generate(success: true))

      expect(described_class.audits_after(account, cursor).map { |row| row.audited_changes['tool_id'] }).to eq(['create_appointment'])
      expect(described_class.audits_after(account, described_class.cursor(account))).to be_empty
    end

    it 'start at zero for an account that has none' do
      expect(described_class.cursor(account)).to eq(0)
    end
  end

  describe '.build' do
    it 'matches each audit row with the next event of the same tool and marks an event without a row as not audited' do
      audit('create_appointment', arguments: { resource_id: 4 }, result: JSON.generate(success: true, status: 'created'))
      events = [event('plan_request'), event('create_appointment'), event('create_appointment')]

      calls = described_class.build(events: events, audits: described_class.audits_after(account, 0))

      expect(calls).to eq([
                            { tool: 'plan_request', success: true, audited: false },
                            { tool: 'create_appointment', success: true, audited: true, agent: 'Запись к врачу', arguments: { 'resource_id' => 4 },
                              result: calls[1][:result] },
                            { tool: 'create_appointment', success: true, audited: false }
                          ])
      expect(calls[1][:result]).to include('created')
    end

    it 'keeps an audit row that has no event, and ignores events of other kinds' do
      audit('add_private_note', arguments: { note: 'x' }, result: 'ok')
      other = event_class.new('llm.chat.request', nil, {})

      calls = described_class.build(events: [other], audits: described_class.audits_after(account, 0))

      expect(calls).to contain_exactly(a_hash_including(tool: 'add_private_note', audited: true))
    end

    it 'takes the success flag of the event' do
      expect(described_class.build(events: [event('handoff', success: false)], audits: []).first).to include(success: false)
    end
  end

  describe '.compact' do
    it 'cuts arguments and results to one short line' do
      calls = [{ tool: 'create_appointment', success: true, audited: true, agent: 'A', arguments: { 'note' => 'x' * 500 }, result: "a\n  b" }]

      line = described_class.compact(calls).first

      expect(line[:arguments].length).to be <= described_class::MAX_ARGUMENTS
      expect(line).to include(tool: 'create_appointment', success: true, audited: true, agent: 'A', result: 'a b')
    end

    it 'leaves out what is not there' do
      expect(described_class.compact([{ tool: 'plan_request', success: true }])).to eq([{ tool: 'plan_request', success: true }])
    end
  end

  describe '.canonical' do
    it 'sorts keys at every depth, so the same call in another key order is the same call' do
      one = { 'b' => 1, 'a' => { 'z' => [{ 'y' => 2, 'x' => 1 }] } }
      other = { a: { z: [{ x: 1, y: 2 }] }, b: 1 }

      expect(described_class.canonical(one)).to eq(described_class.canonical(other))
      expect(described_class.canonical(one).keys).to eq(%w[a b])
    end
  end
end
