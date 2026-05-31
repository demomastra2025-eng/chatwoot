# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::OpenRouterClient do
  let(:account) { instance_double(Account, id: 530) }

  it 'builds a structured OpenRouter runtime request for judge evaluations' do
    captured_request = nil

    expect(Llm::Runtime).to receive(:chat) do |request|
      captured_request = request
      response_for(verdict: 'success', reasoning: 'ok')
    end

    result = described_class.new(account: account, mode: :judge).call(
      thread_id: 'thread-1',
      response_schema: {
        type: 'object',
        required: %w[verdict reasoning],
        properties: {
          verdict: { type: 'string' },
          reasoning: { type: 'string' }
        }
      }
    )

    expect(result).to eq(verdict: 'success', reasoning: 'ok')
    expect(captured_request).to have_attributes(account: account, feature_key: 'copilot')
    expect(captured_request.schema).to have_attributes(name: 'evals.judge.response')
    expect(captured_request.schema.to_json_schema).to include(required: %w[verdict reasoning])
    expect(captured_request.messages.last[:content]).to include('"thread_id":"thread-1"')
    expect(captured_request.observability).to include(feature: 'evals', eval_mode: 'judge', scenario_thread_id: 'thread-1')
  end

  it 'uses user simulator prompts and parses JSON text responses' do
    captured_request = nil

    expect(Llm::Runtime).to receive(:chat) do |request|
      captured_request = request
      response_for('{"content":"подтверждаю"}')
    end

    result = described_class.new(account: account, mode: :user_simulator).call(
      thread_id: 'thread-2',
      system_prompt: 'custom simulator prompt',
      response_contract: {
        type: 'object',
        required: ['content'],
        properties: { content: { type: 'string' } }
      }
    )

    expect(result).to eq(content: 'подтверждаю')
    expect(captured_request).to have_attributes(feature_key: 'copilot')
    expect(captured_request.schema).to have_attributes(name: 'evals.user_simulator.response')
    expect(captured_request.messages.first[:content]).to eq('custom simulator prompt')
  end

  it 'returns plain content for non-structured eval requests' do
    captured_request = nil

    expect(Llm::Runtime).to receive(:chat) do |request|
      captured_request = request
      response_for('plain response')
    end

    result = described_class.new(account: account, mode: :user_simulator).call(thread_id: 'thread-3')

    expect(result).to eq('plain response')
    expect(captured_request).to have_attributes(feature_key: 'editor', schema: nil)
  end

  def response_for(content)
    Struct.new(:content).new(content)
  end
end
