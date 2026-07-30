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

    it 'exposes the active request id without leaking it after the context ends' do
      expect(described_class.request_id).to be_nil

      described_class.with_context(request_id: 'req-active') do
        expect(described_class.request_id).to eq('req-active')
      end

      expect(described_class.request_id).to be_nil
    end

    it 'publishes canonical names for accepted aliases while recording the alias in payload' do
      alias_matrix = {
        'run.started' => 'llm.run.start',
        'llm.run.finished' => 'llm.run.complete',
        'run.failed' => 'llm.run.complete',
        'tool.started' => 'llm.tool.execute',
        'tool.finished' => 'llm.tool.complete',
        'tool.failed' => 'llm.tool.complete',
        'schema.repair' => 'llm.schema.repair_requested'
      }

      events = []
      subscriber = ActiveSupport::Notifications.subscribe(/llm\./) do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      alias_matrix.each do |event_alias, canonical_event_name|
        events.clear
        described_class.publish(event_alias, tool_name: 'lookup_contact')

        expect(events.map(&:name)).to eq([canonical_event_name])
        expect(events.first.payload).to include(
          'canonical_event_name' => canonical_event_name,
          'event_name_alias' => event_alias.start_with?('llm.') ? event_alias : "llm.#{event_alias}",
          'tool_name' => 'lookup_contact'
        )
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'normalizes project case identifiers before publishing context' do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe(/llm\./) do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      described_class.publish('chat.complete', project_case_id: ' crm.lookup_tool ')
      described_class.publish('chat.complete', project_case_id: 'raw customer question')

      expect(events.first.payload['project_case_id']).to eq('crm.lookup_tool')
      expect(events.second.payload).not_to have_key('project_case_id')
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
