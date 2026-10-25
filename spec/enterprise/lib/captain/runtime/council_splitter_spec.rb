# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::CouncilSplitter do
  let(:account) { create(:account) }
  let(:participants) do
    [Captain::Runtime::RoutingSnapshot::Agent.new(id: 119, label: 'Процедуры', card: 'Аудиометрия'),
     Captain::Runtime::RoutingSnapshot::Agent.new(id: 84, label: 'Врачи', card: 'Консультации ЛОР')]
  end
  let(:message) { 'Хочу записаться на консультацию к ЛОРу и в тот же день сделать аудиометрию' }
  let(:open_questions) { [{ number: 3, agent_id: 84, question: 'На какой день?' }, { number: 4, agent_id: 120, question: 'Чужой вопрос' }] }
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:schemas) { [] }
  let(:splitter) do
    described_class.new(account: account, message: message, participants: participants, open_questions: open_questions,
                        observability: { routing_request_id: 'r-1' })
  end

  before do
    allow(Llm::Config).to receive(:model_for).and_call_original
    allow(Llm::Config).to receive(:model_for).with(feature: :council_split, account: account).and_return('openai/gpt-6-luna')
    allow(Llm::Runtime).to receive(:build_chat).and_return(chat)
    allow(chat).to receive(:with_instructions).and_return(chat)
    allow(Llm::StructuredOutputPolicy).to receive(:bind!) do |chat:, schema:|
      schemas << schema
      chat
    end
  end

  def answer_with(parts)
    allow(Llm::Runtime).to receive(:ask).and_return(instance_double(RubyLLM::Message, content: { 'parts' => parts }))
  end

  it 'gives every participant its own words, in the order of the message, with its link to an open question' do
    answer_with([
                  { 'agent_id' => 84, 'fragment' => 'записаться на консультацию к ЛОРу', 'patient' => 'self', 'relation' => 'independent',
                    'link_part_number' => 3, 'link_action' => 'answer' },
                  { 'agent_id' => 119, 'fragment' => 'в тот же день сделать аудиометрию', 'patient' => 'self', 'relation' => 'depends_on',
                    'link_part_number' => nil, 'link_action' => 'new' }
                ])

    result = splitter.split

    expect(result.fallback).to be(false)
    expect(result.parts).to eq([
                                 { 'executor_agent_id' => 84, 'fragment' => 'записаться на консультацию к ЛОРу', 'patient' => 'self',
                                   'relation' => 'independent', 'link_part_number' => 3, 'link_action' => 'answer' },
                                 { 'executor_agent_id' => 119, 'fragment' => 'в тот же день сделать аудиометрию', 'patient' => 'self',
                                   'relation' => 'depends_on', 'link_action' => 'new' }
                               ])
    schema = schemas.first[:schema][:properties][:parts][:items]
    expect(schema[:properties][:agent_id][:enum]).to eq([84, 119])
    expect(schema[:properties][:link_part_number][:enum]).to eq([3, nil])
    expect(Llm::Runtime).to have_received(:build_chat).with(hash_including(feature: :council_split))
  end

  it 'links nothing when the number is an open question of another agent' do
    answer_with([
                  { 'agent_id' => 84, 'fragment' => 'консультация', 'relation' => 'independent', 'link_part_number' => 4, 'link_action' => 'answer' },
                  { 'agent_id' => 119, 'fragment' => 'аудиометрия', 'relation' => 'independent', 'link_part_number' => nil, 'link_action' => 'new' }
                ])

    part = splitter.split.parts.first
    expect(part['link_action']).to eq('new')
    expect(part).not_to have_key('link_part_number')
  end

  it 'falls back to the whole message for every participant when a participant is missing' do
    answer_with([{ 'agent_id' => 84, 'fragment' => 'консультация', 'relation' => 'independent', 'link_part_number' => nil, 'link_action' => 'new' }])

    result = splitter.split

    expect(result).to have_attributes(fallback: true, reason: 'invalid')
    expect(result.parts).to eq([{ 'executor_agent_id' => 84, 'fragment' => message, 'relation' => 'independent', 'link_action' => 'new' },
                                { 'executor_agent_id' => 119, 'fragment' => message, 'relation' => 'independent', 'link_action' => 'new' }])
  end

  it 'falls back when the call fails, keeping exactly the participants' do
    allow(Llm::Runtime).to receive(:ask).and_raise(StandardError, 'provider down')

    result = splitter.split

    expect(result).to have_attributes(fallback: true, reason: 'error')
    expect(result.parts.pluck('executor_agent_id')).to eq([84, 119])
  end

  it 'falls back on the timeout' do
    allow(Llm::Runtime).to receive(:ask).and_raise(Timeout::Error)

    expect(splitter.split).to have_attributes(fallback: true, reason: 'timeout')
  end
end
