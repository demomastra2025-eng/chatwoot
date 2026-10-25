# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RouterBenchmark::Fixture do
  let(:graphs) do
    { '78' => { 'name' => 'SEZIM', 'assistants' => [
      { 'id' => 84, 'name' => 'Врачи', 'routing_description' => 'Главный координатор: запись', 'enabled_tool_ids' => %w[create_appointment],
        'entry_eligible' => true },
      { 'id' => 119, 'name' => 'Процедуры', 'routing_description' => 'ЛОР-процедуры', 'enabled_tool_ids' => %w[create_appointment],
        'entry_eligible' => true },
      { 'id' => 79, 'name' => 'Workspace MCP', 'routing_description' => '', 'entry_eligible' => false }
    ] } }
  end
  let(:scenario) { { 'id' => 'SZ01', 'current' => nil, 'history' => [], 'message' => 'к ЛОРу завтра', 'expected' => 'route_agent_84' } }
  let(:scenarios) { { 'suites' => [{ 'suite' => 'sezim', 'account_id' => 78, 'scenarios' => [scenario] }] } }
  let(:proposals) { { 'assistants' => [{ 'assistant_id' => 84, 'routing_description' => 'Общие вопросы. Запись к ЛОР-врачам.' }] } }

  it 'builds the candidates of a suite from the graph, internal assistants left out, with the cards of the chosen source' do
    proposed = described_class.new(graphs, scenarios, cards: 'proposed', proposals: proposals).suites.first
    prod = described_class.new(graphs, scenarios, cards: 'prod').suites.first

    expect(proposed.candidates.map(&:id)).to eq([84, 119])
    expect(proposed.candidates.first.routing_description).to eq('Общие вопросы. Запись к ЛОР-врачам.')
    # An agent without a proposal keeps the card it has on PROD.
    expect(proposed.candidates.last.routing_description).to eq('ЛОР-процедуры')
    expect(prod.candidates.first.routing_description).to eq('Главный координатор: запись')
    expect(proposed.clinic).to eq('SEZIM')
  end

  it 'refuses an expected key that is not a criteria key or names an agent that is not a candidate' do
    expect { described_class.new(graphs, scenarios_with('expected' => 'route_to_doctor'), cards: 'prod') }.to raise_error(described_class::Invalid)
    expect { described_class.new(graphs, scenarios_with('expected' => 'route_agent_79'), cards: 'prod') }.to raise_error(described_class::Invalid)
    expect { described_class.new(graphs, scenarios_with('expected' => 'stay_current'), cards: 'prod') }.to raise_error(described_class::Invalid)
  end

  it 'loads the committed scenario file strictly' do
    committed = JSON.parse(File.read(Rails.root.join('script/captain/router_benchmark/router_scenarios.json')))
    ids = committed['suites'].flat_map { |suite| suite['scenarios'].pluck('id') }

    expect(ids.size).to eq(54)
    expect(ids).to include('SZ01', 'A11', 'I06')
    expect(committed['suites'].flat_map { |suite| suite['scenarios'].pluck('expected') }).to all(match(described_class::KEY))
  end

  def scenarios_with(changes)
    { 'suites' => [{ 'suite' => 'sezim', 'account_id' => 78, 'scenarios' => [scenario.merge(changes)] }] }
  end
end
