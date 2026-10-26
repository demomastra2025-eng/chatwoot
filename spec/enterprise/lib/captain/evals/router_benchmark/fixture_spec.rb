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

    expect(ids.size).to eq(82)
    expect(ids).to include('AM01', 'IM01')
    expect(ids).to include('SZ01', 'A11', 'I06')
    # A plain thanks or greeting needs no answer (no_reply_needed), whoever leads the dialog, and is never a council; a thanks that
    # also asks for two agents' services is a council.
    expect(ids).to include('AS06', 'IS06', 'IS07', 'SS05', 'SZ20')
    expected = committed['suites'].flat_map { |suite| suite['scenarios'] }.to_h { |scenario| [scenario['id'], scenario['expected']] }
    expect(expected.values_at('AS05', 'AS06', 'IS03', 'IS06', 'SZ18', 'SZ20', 'SS03', 'SS05')).to all(eq('no_reply_needed'))
    expect(expected['IS07']).to start_with('council_')
    traps = committed['suites'].flat_map { |suite| suite['scenarios'] }.filter_map { |scenario| scenario['trap'] }
    expect(traps.tally).to eq('human' => 3, 'injection' => 4, 'false_council' => 9)
    expect(committed['suites'].flat_map { |suite| suite['scenarios'].pluck('expected') }).to all(match(described_class::KEY))
  end

  it 'has reply suggestion scenarios with a sticky agent and short replies in every clinic graph' do
    committed = JSON.parse(File.read(Rails.root.join('script/captain/router_benchmark/router_scenarios.json')))
    sticky = committed['suites'].to_h { |suite| [suite['suite'], suite['scenarios'].select { |item| item['type'].to_s.start_with?('suggestion') }] }

    expect(sticky.values.sum(&:size)).to be >= 10
    expect(sticky.keys).to contain_exactly('aliya_owner18', 'intermedical', 'sezim_bogenbay')
    expect(sticky.values).to all(satisfy { |items| items.pluck('type').uniq.size >= 2 })
    # A short reply mid-booking without a sticky agent (the first suggestion of a dialog) must reach the agent of the booking.
    no_sticky_booking = ->(item) { item['type'] == 'suggestion_no_sticky' && item['expected'] != "route_agent_#{item['anchor']}" }
    expect(sticky.values).to all(satisfy { |items| items.any?(&no_sticky_booking) })
    expect(sticky.values.flatten.reject { |item| item.key?('sticky') }).to all(include('suggestion' => true, 'anchor' => be_present))
    expect(sticky.values.flatten.select { |item| item.key?('sticky') }).to all(include('current' => nil))
  end

  it 'takes a sticky agent for the current agent of a stay, and refuses one that is not a candidate' do
    stay = { 'current' => nil, 'sticky' => 119, 'message' => 'Да, на 14:00', 'expected' => 'stay_current' }

    expect { described_class.new(graphs, scenarios_with(stay), cards: 'prod') }.not_to raise_error
    expect { described_class.new(graphs, scenarios_with(stay.merge('sticky' => 79)), cards: 'prod') }.to raise_error(described_class::Invalid)
    expect { described_class.new(graphs, scenarios_with(stay.merge('current' => 84)), cards: 'prod') }.to raise_error(described_class::Invalid)
    expect do
      described_class.new(graphs, scenarios_with('suggestion' => true, 'anchor' => 79, 'expected' => 'route_agent_84'), cards: 'prod')
    end.to raise_error(described_class::Invalid)
  end

  it 'lets only a suggestion expect undecided (the escalation names no agent either)' do
    undecided = { 'suggestion' => true, 'anchor' => 84, 'history' => [{ 'role' => 'agent', 'text' => 'Ждём вас.' }],
                  'message' => 'Спасибо!', 'expected' => 'undecided' }

    expect { described_class.new(graphs, scenarios_with(undecided), cards: 'prod') }.not_to raise_error
    expect { described_class.new(graphs, scenarios_with(undecided.except('suggestion')), cards: 'prod') }
      .to raise_error(described_class::Invalid, /only a suggestion/)
  end

  def scenarios_with(changes)
    { 'suites' => [{ 'suite' => 'sezim', 'account_id' => 78, 'scenarios' => [scenario.merge(changes)] }] }
  end
end
