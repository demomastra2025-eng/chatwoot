# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RouterBenchmark::Runner do
  let(:account) { create(:account) }
  let(:graphs) do
    { '78' => { 'name' => 'SEZIM', 'assistants' => [
      { 'id' => 84, 'name' => 'Врачи', 'routing_description' => 'Запись к ЛОР-врачам', 'enabled_tool_ids' => %w[create_appointment] },
      { 'id' => 119, 'name' => 'Процедуры', 'routing_description' => 'ЛОР-процедуры', 'enabled_tool_ids' => %w[create_appointment] }
    ] } }
  end
  let(:scenarios) do
    { 'suites' => [{ 'suite' => 'sezim', 'account_id' => 78, 'scenarios' => [
      { 'id' => 'SZ01', 'current' => nil, 'history' => [], 'message' => 'к ЛОРу завтра', 'expected' => 'route_agent_84' }
    ] }] }
  end
  let(:fixture) { Captain::Evals::RouterBenchmark::Fixture.new(graphs, scenarios, cards: 'prod') }

  it 'asks each model alone, with the same questions and no escalation, and runs the production pipeline on the same turn' do
    raw = Captain::Runtime::DecisionRouter::Decision.new(
      key: 'inconsistent', kind: 'inconsistent', agent_ids: [], first_confidence: 0.6,
      first_answers: 'route_mode=council include_agent_84=yes include_agent_119=no'
    )
    decision = Captain::Runtime::DecisionRouter::Decision.new(
      key: 'route_agent_84', kind: 'agent', agent_ids: [84], escalated: true, escalation_trigger: 'inconsistent',
      first_choice: 'inconsistent', first_confidence: 0.6, decided_by: 'escalation:openai/gpt-6-luna', chain_position: 1
    )
    routers = []
    allow(Captain::Runtime::DecisionRouter).to receive(:new) do |_snapshot, **options|
      routers << options.slice(:escalate, :chain_models)
      instance_double(Captain::Runtime::DecisionRouter, decide: options[:chain_models] ? raw : decision)
    end
    progress = StringIO.new

    rows = described_class.new(fixture: fixture, account: account,
                               options: { models: ['typesafe/jev-1.14'], chain: true, budget_usd: 1, progress: progress }).call

    expect(routers).to eq([{ escalate: false, chain_models: ['typesafe/jev-1.14'] }, { escalate: true, chain_models: nil }])
    expect(rows.map { |row| [row.mode, row.got, row.expected] })
      .to eq([%w[model inconsistent route_agent_84], %w[pipeline route_agent_84 route_agent_84]])
    expect(rows.last).to have_attributes(escalated: true, decided_by: 'escalation:openai/gpt-6-luna')
    expect(progress.string).to include('SZ01 pipeline expected route_agent_84 got route_agent_84')

    report = Captain::Evals::RouterBenchmark::Report.new(rows).to_h
    expect(report[:models]['typesafe/jev-1.14'][:accuracy]).to eq(0.0)
    expect(report[:pipeline]).to include(accuracy: 1.0, escalation_rate: 1.0)
    expect(report[:gate][:checks][:must_pass]).to be(true)
  end

  it 'makes the listed decision models fail only while it runs, so the pipeline rows show which model of the chain answered' do
    failures = []
    allow(Captain::Runtime::DecisionRouter).to receive(:new) do
      instance_double(Captain::Runtime::DecisionRouter).tap do |router|
        allow(router).to receive(:decide) do
          Llm::OpenRouterDecisionClient.choose(state: {}, criteria: {}, instructions: 'x', model: 'perplexity/pplx-decider-v1.2', timeout: 1)
        rescue Llm::OpenRouterDecisionClient::Error => e
          failures << e.message
          Captain::Runtime::DecisionRouter::Decision.new(key: 'route_agent_84', kind: 'agent', agent_ids: [84], first_confidence: 0.9,
                                                         decided_by: 'typesafe/jev-1.14', chain_position: 2)
        end
      end
    end

    rows = described_class.new(fixture: fixture, account: account,
                               options: { chain: true, fail_models: ['perplexity/pplx-decider-v1.2'], budget_usd: 1 }).call

    expect(failures).to eq(['Simulated error of the decision model (router benchmark).'])
    expect(rows.sole).to have_attributes(got: 'route_agent_84', decided_by: 'typesafe/jev-1.14', chain_position: 2)
    # After the run the model is called for real again: here it stops at the missing key, not at the simulation.
    expect { Llm::OpenRouterDecisionClient.choose(state: {}, criteria: {}, instructions: 'x', model: 'perplexity/pplx-decider-v1.2') }
      .to raise_error(ArgumentError)
  end

  it 'runs the pipeline on another chain when asked, with the escalation' do
    decision = Captain::Runtime::DecisionRouter::Decision.new(key: 'route_agent_84', kind: 'agent', agent_ids: [84], first_confidence: 0.9,
                                                              decided_by: 'inception/mercury-decide', chain_position: 1)
    allow(Captain::Runtime::DecisionRouter).to receive(:new).and_return(instance_double(Captain::Runtime::DecisionRouter, decide: decision))
    chain = %w[inception/mercury-decide microsoft/microsoft-decision-1 openai/gpt-6-luna-decisions]

    rows = described_class.new(fixture: fixture, account: account, options: { chain_models: chain, budget_usd: 1 }).call

    expect(Captain::Runtime::DecisionRouter).to have_received(:new).with(anything, hash_including(escalate: true, chain_models: chain))
    expect(rows.sole).to have_attributes(mode: 'pipeline', decided_by: 'inception/mercury-decide')
  end

  it 'plays only the listed scenarios and refuses an unknown failure mode' do
    allow(Captain::Runtime::DecisionRouter).to receive(:new)

    expect(described_class.new(fixture: fixture, account: account, options: { only: ['A01'], budget_usd: 1 }).call).to eq([])
    expect(Captain::Runtime::DecisionRouter).not_to have_received(:new)
    expect { described_class.new(fixture: fixture, account: account, options: { fail_models: ['x'], fail_mode: 'slow' }) }
      .to raise_error(ArgumentError)
  end
end
