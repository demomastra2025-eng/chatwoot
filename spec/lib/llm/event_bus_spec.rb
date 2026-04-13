# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::EventBus do
  describe '.publish' do
    it 'publishes namespaced ActiveSupport notifications with normalized keys' do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.moderation.complete') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      described_class.publish('moderation.complete', feature: :assistant, stage: :input)

      expect(events.size).to eq(1)
      expect(events.first.payload).to include('feature' => :assistant, 'stage' => :input)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'allows wrappers to enrich the published payload from inside the block' do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.chat.complete') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      result = described_class.publish('chat.complete', feature: 'assistant') do |payload|
        payload['status'] = 'success'
        'response'
      end

      expect(result).to eq('response')
      expect(events.last.payload).to include('feature' => 'assistant', 'status' => 'success')
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'propagates correlation context into nested events' do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe(/llm\./) do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      described_class.publish('chat.complete', feature: 'assistant', trace_id: 'trace-123') do
        described_class.publish('schema.invalid', reason: 'invalid_schema')
      end

      parent_event = events.find { |event| event.name == 'llm.chat.complete' }
      child_event = events.find { |event| event.name == 'llm.schema.invalid' }

      expect(parent_event.payload['request_id']).to be_present
      expect(child_event.payload).to include(
        'feature' => 'assistant',
        'trace_id' => 'trace-123',
        'request_id' => parent_event.payload['request_id']
      )
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'allows callers to establish a request context before multiple sibling events' do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe(/llm\./) do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      described_class.with_context(feature: 'assistant', request_id: 'req-123', session_id: 'session-1') do
        described_class.publish('safety.blocked', reason: 'custom_blocklist')
        described_class.publish('moderation.complete', status: 'flagged')
      end

      expect(events.map { |event| event.payload['request_id'] }.uniq).to eq(['req-123'])
      expect(events.map { |event| event.payload['session_id'] }.uniq).to eq(['session-1'])
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
