require 'rails_helper'

RSpec.describe AutomationRules::ExecutionService do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:rule) { create(:automation_rule, account: account, execution_schedule: {}) }

  describe '#perform' do
    it 'queues an immediate rule through the isolated idempotent execution job' do
      expect do
        described_class.new(rule: rule, record: conversation, execution_key: 'immediate-event-key').perform
      end.to have_enqueued_job(AutomationRules::ExecuteRuleJob).with(
        rule.id,
        rule.execution_signature,
        conversation.to_global_id.to_s,
        {},
        nil,
        'immediate-event-key',
        rule.lifecycle_generation
      )
    end

    it 'queues the whole rule for a delayed execution' do
      rule.update!(
        execution_schedule: {
          timing_mode: 'relative',
          relative_anchor: 'conversation.created_at',
          relative_offset_seconds: 3600,
          timezone: 'UTC'
        }
      )

      expect do
        described_class.new(rule: rule, record: conversation).perform
      end.to have_enqueued_job(AutomationRules::ExecuteRuleJob)
    end

    it 'uses the supplied stable event key for delayed execution' do
      rule.update!(
        execution_schedule: {
          timing_mode: 'relative',
          relative_anchor: 'conversation.created_at',
          relative_offset_seconds: 3600,
          timezone: 'UTC'
        }
      )

      described_class.new(
        rule: rule,
        record: conversation,
        execution_key: 'stable-event-key'
      ).perform

      expect(AutomationRules::ExecuteRuleJob).to have_been_enqueued.with(
        rule.id,
        rule.execution_signature,
        conversation.to_global_id.to_s,
        {},
        nil,
        'stable-event-key',
        rule.lifecycle_generation
      )
    end

    it 'safely skips a relative schedule whose runtime anchor is unavailable' do
      conversation.update_column(:waiting_since, nil) # rubocop:disable Rails/SkipsModelValidations
      rule.update!(
        execution_schedule: {
          timing_mode: 'relative',
          relative_anchor: 'conversation.waiting_since',
          relative_offset_seconds: 60,
          timezone: 'UTC'
        }
      )

      expect do
        described_class.new(rule: rule, record: conversation).perform
      end.not_to have_enqueued_job(AutomationRules::ExecuteRuleJob)
    end
  end

  describe '.execution_key_for' do
    it 'returns the same key for duplicate event data regardless of hash order' do
      event_timestamp = Time.current
      first_event = Events::Base.new(
        'conversation.updated',
        event_timestamp,
        { changed_attributes: { status: %w[open resolved], priority: %w[normal high] } }
      )
      duplicate_event = Events::Base.new(
        'conversation.updated',
        event_timestamp,
        { changed_attributes: { priority: %w[normal high], status: %w[open resolved] } }
      )

      first_key = described_class.execution_key_for(event: first_event, record: conversation)
      duplicate_key = described_class.execution_key_for(event: duplicate_event, record: conversation)

      expect(duplicate_key).to eq(first_key)
    end

    it 'keeps the key stable when an action changes the source record version' do
      event = Events::Base.new('conversation.updated', Time.current, { changed_attributes: {} })
      first_key = described_class.execution_key_for(event: event, record: conversation)
      conversation.update!(updated_at: 1.minute.from_now)

      expect(described_class.execution_key_for(event: event, record: conversation.reload)).to eq(first_key)
    end

    it 'changes the key for a distinct event occurrence' do
      first_event = Events::Base.new('conversation.updated', Time.current, { changed_attributes: {} })
      next_event = Events::Base.new('conversation.updated', 1.minute.from_now, { changed_attributes: {} })

      first_key = described_class.execution_key_for(event: first_event, record: conversation)
      expect(described_class.execution_key_for(event: next_event, record: conversation)).not_to eq(first_key)
    end
  end
end
