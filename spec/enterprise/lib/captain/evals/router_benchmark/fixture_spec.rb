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

    expect(ids.size).to eq(106)
    expect(ids).to include('AM01', 'IM01')
    expect(ids).to include('SZ01', 'A11', 'I06')
    # A plain thanks needs no answer (no_reply_needed), whoever leads the dialog, and is never a council; a thanks that also asks for
    # two agents' services is a council. An ok, a thumbs-up or «Жарайды» to an offered time accepts it, and a first greeting opens the
    # dialog: neither is no_reply_needed.
    expect(ids).to include('AS06', 'IS06', 'IS07', 'SS05', 'SZ20')
    expected = committed['suites'].flat_map { |suite| suite['scenarios'] }.to_h { |scenario| [scenario['id'], scenario['expected']] }
    expect(expected.values_at('AS05', 'AS06', 'IS03', 'IS06', 'SZ18', 'SS03', 'SS05', 'AS07', 'IS08', 'SS06', 'AN03', 'IN02', 'SN02', 'SZ20'))
      .to eq((%w[no_reply_needed] * 7) + (%w[stay_current] * 3) + %w[route_agent_109 route_agent_113 route_agent_119 route_agent_84])
    expect(expected['IS07']).to start_with('council_')
    # Suggestion eval 26.10: a plain question about free times for a child went to staff as the first message of a dialog. It goes to the
    # agent of the service; staff only answer a request for a person (Russian or Kazakh).
    expect(expected.values_at('A20', 'I20', 'SZ21')).to eq(%w[route_agent_77 route_agent_85 route_agent_84])
    expect(expected.values_at('A21', 'I21', 'SZ22', 'SZ23')).to eq(%w[human_handoff] * 4)
    # Review of the human_handoff gate: a call-back asked as a question, the front desk, a demand to stop writing, English and the Kazakh
    # slang «админ» are wordings a keyword list may miss; the staff decision of the model stands when no agent is a plausible answer.
    expect(expected.values_at('A22', 'A23', 'I22', 'I23', 'SZ24', 'SZ25')).to eq(%w[human_handoff] * 6)
    # Review of quality-fixes-1: a request for a person with no keyword (anybody alive, the doctor in person, English) went to an agent.
    expect(expected.values_at('A24', 'A25', 'A26')).to eq(%w[human_handoff] * 3)
    # A yes to a time that staff offered, and a refusal after a reminder, are no courtesy: the agent answers.
    expect(expected.values_at('AS08', 'AS09')).to eq(%w[stay_current] * 2)
    traps = committed['suites'].flat_map { |suite| suite['scenarios'] }.filter_map { |scenario| scenario['trap'] }
    expect(traps.tally).to eq('human' => 16, 'injection' => 4, 'false_council' => 9)
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

  # The router always names who answers since 26.10 (no escalation that could name nobody).
  it 'refuses undecided as an expectation' do
    undecided = { 'suggestion' => true, 'anchor' => 84, 'message' => 'Спасибо!', 'expected' => 'undecided' }

    expect { described_class.new(graphs, scenarios_with(undecided), cards: 'prod') }.to raise_error(described_class::Invalid)
  end

  def scenarios_with(changes)
    { 'suites' => [{ 'suite' => 'sezim', 'account_id' => 78, 'scenarios' => [scenario.merge(changes)] }] }
  end
end
