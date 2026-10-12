# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::Runner do
  let(:fixture_data) do
    {
      workspace: {
        agents: [{ name: 'Регистратор', routing_description: 'Запись', instructions: 'Отвечай по-русски.',
                   tool_ids: %w[faq_lookup get_my_contact], model: 'openai/gpt-6-luna' }],
        contacts: [{ key: 'patient', name: 'Дана Нурланова' }]
      },
      dialogues: %w[first second third].map do |id|
        { id: id, contact: 'patient',
          turns: [{ customer: 'Здравствуйте', expect: { agent: 'Регистратор', council: false } }] }
      end
    }
  end
  let(:out) { Rails.root.join('tmp', "isolation-benchmark-#{SecureRandom.uuid}.json") }
  let(:seen) { [] }

  # The scripted runtime reports what the workspace holds when it is called, then leaves rows behind.
  def script_runtime(&block)
    allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |assistant:, conversation:, **|
      block.call(conversation)
      instance_double(Captain::Assistant::AgentRunnerService,
                      generate_response: { 'agent_id' => assistant.id, 'response' => 'Здравствуйте!',
                                           'captain_request_id' => 'synthetic-request' })
    end
  end

  def stub_fixture
    fixture = Captain::Evals::RoutingBenchmark::Fixture.new(fixture_data)
    allow(Captain::Evals::RoutingBenchmark::Guard).to receive(:check!).and_return(true)
    allow(Captain::Evals::RoutingBenchmark::Guard).to receive(:restrict_http!).and_return(true)
    allow(Dir).to receive(:glob).and_call_original
    allow(Dir).to receive(:glob).with('synthetic/*.yml').and_return(['synthetic/case.yml'])
    allow(Captain::Evals::RoutingBenchmark::Fixture).to receive(:load).and_return(fixture)
  end

  def run_benchmark(runs: 1)
    runner = described_class.new(fixtures: 'synthetic/*.yml', runs: runs, budget_usd: 1, out: out)
    allow(runner).to receive(:write_report)
    runner.call
  end

  it 'gives every dialogue a fresh workspace, so state never leaks from one dialogue to the next' do
    stub_fixture
    script_runtime do |conversation|
      seen << { account_id: conversation.account_id, contacts: Contact.where(account_id: conversation.account_id).pluck(:name) }
      Contact.create!(account: conversation.account, name: "Утекший контакт #{seen.size}")
      Contact.where(account_id: conversation.account_id, name: 'Дана Нурланова').update_all(name: 'Изменённый контакт')
    end

    report = run_benchmark

    expect(report.dig(:aggregates, :passed)).to eq(3)
    expect(seen.pluck(:account_id).uniq.size).to eq(3)
    expect(seen.pluck(:contacts)).to all(eq(['Дана Нурланова']))
  end

  it 'rolls every dialogue back, including across runs' do
    stub_fixture
    script_runtime { |conversation| seen << conversation.account_id }

    run_benchmark(runs: 2)

    expect(seen.uniq.size).to eq(6)
    expect(Account.where(id: seen)).to be_empty
  end

  it 'reports the isolation mode and the council aggregates' do
    stub_fixture
    script_runtime { |_conversation| nil }

    report = run_benchmark

    expect(report).to include(isolation: 'workspace_per_dialogue', warnings: [])
    expect(report[:aggregates]).to include(council_expected: 0, council_event_missing: 0, council_unexpected: 0,
                                           passed_ignoring_council_signal: 3, council_detection: 1.0)
  end

  it 'warns when turns expect a council and the runtime never emitted captain.council.started' do
    fixture_data[:dialogues].each { |dialogue| dialogue[:turns].first[:expect][:council] = true }
    stub_fixture
    script_runtime { |_conversation| nil }

    report = run_benchmark

    expect(report[:aggregates]).to include(council_expected: 3, council_event_missing: 3, passed: 0,
                                           passed_ignoring_council_signal: 3, routing_accuracy: 1.0)
    expect(report[:warnings].sole).to match(/council_event_missing: 3 of 3 .*captain\.council\.started/)
  end
end
