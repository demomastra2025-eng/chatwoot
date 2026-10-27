# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::AnswerStream do
  def wrapper_for(source:, callbacks: {}, context: {})
    Captain::Runtime::RunContext.new({ state: { source: source } }.merge(context), callbacks: callbacks)
  end

  let(:listener) { ->(*) {} }
  let(:callbacks) { { answer_delta: [listener] } }

  describe '.enabled?' do
    it 'is on for the agent of a reply suggestion that has a listener' do
      expect(described_class.enabled?(wrapper_for(source: 'reply_suggestion', callbacks: callbacks))).to be(true)
    end

    it 'is off when nothing listens' do
      expect(described_class.enabled?(wrapper_for(source: 'reply_suggestion'))).to be(false)
      expect(described_class.enabled?(wrapper_for(source: 'reply_suggestion', callbacks: { answer_delta: [] }))).to be(false)
    end

    it 'is off for a live conversation and for the playground, with a listener or without' do
      %w[incoming_message playground].each do |source|
        expect(described_class.enabled?(wrapper_for(source: source, callbacks: callbacks))).to be(false)
      end
    end

    it 'is off for the part of a council, whose text is not the answer' do
      wrapper = wrapper_for(source: 'reply_suggestion', callbacks: callbacks, context: { part_run: true })

      expect(described_class.enabled?(wrapper)).to be(false)
    end

    it 'is off without a run' do
      expect(described_class.enabled?(nil)).to be(false)
    end
  end

  describe '.consumer' do
    it 'hands the text of each chunk to the listeners, with the agent and the run' do
      calls = []
      wrapper = wrapper_for(source: 'reply_suggestion', callbacks: { answer_delta: [->(agent, text, run) { calls << [agent, text, run] }] })

      consume = described_class.consumer('Диана', wrapper)
      consume.call(RubyLLM::Chunk.new(role: :assistant, content: 'Здравст'))
      consume.call(RubyLLM::Chunk.new(role: :assistant, content: 'вуйте'))

      expect(calls).to eq([['Диана', 'Здравст', wrapper], ['Диана', 'вуйте', wrapper]])
    end

    it 'says nothing for a chunk without text: a piece of a tool call, the usage at the end' do
      calls = []
      wrapper = wrapper_for(source: 'reply_suggestion', callbacks: { answer_delta: [->(*args) { calls << args }] })
      consume = described_class.consumer('Диана', wrapper)

      consume.call(RubyLLM::Chunk.new(role: :assistant, content: nil))
      consume.call(RubyLLM::Chunk.new(role: :assistant, content: ''))
      tool_call = RubyLLM::ToolCall.new(id: 'call_0', name: 'x', arguments: {})
      consume.call(RubyLLM::Chunk.new(role: :assistant, content: nil, tool_calls: { 'call_0' => tool_call }))

      expect(calls).to be_empty
    end

    it 'never raises into the call it listens to' do
      wrapper = wrapper_for(source: 'reply_suggestion', callbacks: { answer_delta: [->(*) { raise 'broken listener' }] })
      allow(Rails.logger).to receive(:warn)

      expect { described_class.consumer('Диана', wrapper).call(RubyLLM::Chunk.new(role: :assistant, content: 'текст')) }.not_to raise_error
    end
  end
end
