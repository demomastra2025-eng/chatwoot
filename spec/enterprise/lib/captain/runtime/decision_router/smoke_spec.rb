# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::DecisionRouter::Smoke do
  let(:account) { create(:account) }
  let(:smoke) { described_class.new(account: account) }
  let(:calls) { [] }

  def answer_with(mode, yes)
    lambda do |question:, models:, **|
      calls << { model: models.sole, question: question }
      choices = question[:questions].keys.index_with { |name| name == "include_agent_#{yes}" ? 'yes' : 'no' }.merge('route_mode' => mode)
      answers = choices.transform_values { |choice| Llm::OpenRouterDecisionClient::Answer.new(choice: choice, confidence: 0.9) }
      Llm::DecisionChain::Result.new(answers: answers, model: models.sole, position: 1)
    end
  end

  it 'asks every model of the routing chain alone and reports each one, with no escalation model' do
    allow(Llm::DecisionChain).to receive(:decide, &answer_with('route_agent', 1))

    rows = smoke.call

    expect(calls.pluck(:model)).to eq(Llm::DecisionChain.models(:agent_routing))
    expect(rows.map { |row| [row.role, row.model, row.ok, row.decision] }).to eq(
      [['chain#1', 'perplexity/pplx-decider-v1.2', true, 'route_agent_1'], ['chain#2', 'inception/mercury-decide', true, 'route_agent_1'],
       ['chain#3', 'microsoft/microsoft-decision-1', true, 'route_agent_1']]
    )
    expect(rows).to all(have_attributes(latency_ms: be >= 0))
    expect(described_class.ok?(rows)).to be(true)
  end

  it 'reports a model that fails, with the error class only, and resolves a council of one agent into a route' do
    allow(Llm::DecisionChain).to receive(:decide) do |models:, **kwargs|
      if models.sole == 'inception/mercury-decide'
        raise Llm::DecisionChain::ExhaustedError.new(feature: :agent_routing, attempts: [{ model: models.sole, error_class: 'Timeout::Error' }])
      end

      answer_with(models.sole == 'perplexity/pplx-decider-v1.2' ? 'council' : 'route_agent', 2).call(models: models, **kwargs)
    end

    rows = smoke.call

    expect(rows.map { |row| [row.ok, row.decision, row.error] }).to eq(
      [[true, 'route_agent_2', nil], [false, nil, 'Llm::DecisionChain::ExhaustedError:Timeout::Error'], [true, 'route_agent_2', nil]]
    )
    expect(described_class.ok?(rows)).to be(false)
  end

  it 'checks by default every account whose channel routes among two or more agents, not the account of the first agent' do
    solo = create(:account)
    create(:captain_assistant, account: solo, active: true, routing_description: 'Всё')
    create(:captain_inbox, inbox: create(:inbox, account: solo))
    clinic = create(:account)
    create(:captain_assistant, account: clinic, active: true, routing_description: 'Запись к ЛОР-врачам')
    create(:captain_assistant, account: clinic, active: true, routing_description: 'ЛОР-процедуры')
    create(:captain_inbox, inbox: create(:inbox, account: clinic))

    expect(described_class.routed_accounts).to eq([clinic])
  end

  it 'prints no key, no prompt and no text of the turn' do
    allow(Llm::DecisionChain).to receive(:decide, &answer_with('route_agent', 1))

    printed = smoke.call.map(&:to_s).join("\n")

    expect(printed).to include('perplexity/pplx-decider-v1.2', 'ok decision=route_agent_1', 'latency_ms=')
    expect(printed).not_to include(described_class::MESSAGE, 'Doctors', Captain::Runtime::DecisionRouter::INSTRUCTIONS.first(40))
    expect(calls.first[:question][:state][:latest_message]).to eq(described_class::MESSAGE)
  end
end
