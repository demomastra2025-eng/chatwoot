# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::DecisionRouter::Escalation do
  let(:account) { create(:account) }
  let(:agents) do
    [Captain::Runtime::RoutingSnapshot::Agent.new(id: 84, label: 'Врачи', card: 'Запись к ЛОР-врачам'),
     Captain::Runtime::RoutingSnapshot::Agent.new(id: 119, label: 'Процедуры', card: 'ЛОР-процедуры')]
  end
  let(:snapshot) { Captain::Runtime::RoutingSnapshot.new(agents: agents, latest_message: 'к ЛОРу завтра', human_available: true) }
  let(:questions) { Captain::Runtime::DecisionRouter::Questions.build(snapshot, instructions: 'decide') }
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:escalation) { described_class.new(account: account, timeout: 5, effort: 'high', model: 'openai/gpt-6-luna') }
  let(:bound_schemas) { [] }
  let(:route_to_doctors) { { 'route_mode' => 'route_agent', 'include_agent_84' => 'yes', 'include_agent_119' => 'no' } }

  before do
    allow(Llm::Runtime).to receive(:build_chat).and_return(chat)
    allow(chat).to receive(:with_instructions).and_return(chat)
    allow(Llm::StructuredOutputPolicy).to receive(:bind!) do |chat:, schema:|
      bound_schemas << schema
      chat
    end
  end

  def answer_with(content)
    allow(Llm::Runtime).to receive(:ask).and_return(instance_double(RubyLLM::Message, content: content))
  end

  it 'answers every question with one of its keys and gives a short reason, from the structured answer' do
    answer_with(route_to_doctors.merge('reason' => "agent 84 books ENT doctors\n#{'x' * 300}"))

    result = escalation.choose(state: snapshot.to_state, questions: questions, instructions: 'decide')

    expect(result).to have_attributes(choices: route_to_doctors, model: 'openai/gpt-6-luna')
    expect(result.reason.length).to be_between(1, described_class::REASON_LIMIT)
    expect(result.reason).not_to include("\n")
    properties = bound_schemas.first.dig(:schema, :properties)
    expect(properties['route_mode'][:enum]).to eq(%w[route_agent council human_handoff])
    expect(properties['include_agent_84'][:enum]).to eq(%w[yes no])
    expect(bound_schemas.first.dig(:schema, :required)).to eq(%w[route_mode include_agent_84 include_agent_119 reason])
    expect(Llm::Runtime).to have_received(:build_chat).with(hash_including(feature: :agent_routing_escalation, model: 'openai/gpt-6-luna'))
  end

  it 'gives the model the same questions with their keys and descriptions, and the state as the user message' do
    answer_with(route_to_doctors.merge('reason' => 'x').to_json)

    escalation.choose(state: snapshot.to_state, questions: questions, instructions: 'decide')

    expect(chat).to have_received(:with_instructions) do |prompt|
      expect(prompt).to start_with('decide')
      questions.to_h.each do |name, question|
        expect(prompt).to include("Question #{name} (answer with one key):")
        question[:criteria].each { |key, description| expect(prompt).to include("- #{key}: #{description}") }
      end
    end
    expect(Llm::Runtime).to have_received(:ask).with(chat, snapshot.to_state.to_json, hash_including(model: 'openai/gpt-6-luna'))
  end

  it 'raises escalation_invalid for an answer outside the keys or a missing answer' do
    answer_with(route_to_doctors.merge('route_mode' => 'route_agent_84', 'reason' => 'x'))
    expect { escalation.choose(state: {}, questions: questions, instructions: 'decide') }
      .to raise_error(Captain::Runtime::DecisionRouter::EscalationError) { |error| expect(error.reason).to eq('escalation_invalid') }

    answer_with(route_to_doctors.except('include_agent_119').merge('reason' => 'x'))
    expect { escalation.choose(state: {}, questions: questions, instructions: 'decide') }
      .to raise_error(Captain::Runtime::DecisionRouter::EscalationError) { |error| expect(error.reason).to eq('escalation_invalid') }
  end

  it 'raises escalation_unavailable when the call fails or runs out of time' do
    allow(Llm::Runtime).to receive(:ask).and_raise(Timeout::Error)

    expect { escalation.choose(state: {}, questions: questions, instructions: 'decide') }
      .to raise_error(Captain::Runtime::DecisionRouter::EscalationError) do |error|
        expect(error.reason).to eq('escalation_unavailable')
        expect(error.models_tried).to eq(['openai/gpt-6-luna'])
      end
  end

  it 'raises escalation_unavailable when no model is configured' do
    allow(Llm::Config).to receive(:model_for).and_return(nil)

    expect { described_class.new(account: account, timeout: 5, effort: 'high').choose(state: {}, questions: questions, instructions: 'x') }
      .to raise_error(Captain::Runtime::DecisionRouter::EscalationError) { |error| expect(error.detail).to eq('no_model') }
  end
end
