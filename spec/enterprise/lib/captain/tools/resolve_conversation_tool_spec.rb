require 'rails_helper'

RSpec.describe Captain::Tools::ResolveConversationTool do
  let(:account) { create(:account) }
  let(:assistant) do
    create(
      :captain_assistant,
      account: account,
      config: {
        'outcome_reason_settings' => {
          'completion_reasons' => [{ 'id' => 'other', 'label' => 'Other', 'active' => true }]
        }
      }
    )
  end
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :open) }
  let(:tool) { described_class.new(assistant) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id } }) }

  before do
    Current.executed_by = assistant
  end

  after do
    Current.reset
  end

  describe 'resolving a conversation' do
    it 'does not resolve when automatic completion is disabled for the assistant' do
      assistant.update!(config: assistant.config.merge('auto_completion_enabled' => false))

      expect(tool.perform(tool_context)).to eq('Automatic completion is disabled for this assistant')
      expect(conversation.reload).to be_open
    end

    it 'marks resolved and enqueues an activity message with the reason when provided' do
      result = tool.perform(tool_context, reason: 'Possible spam')
      payload = JSON.parse(result)

      expect(conversation.reload).to be_resolved
      expect(payload).to include(
        'action' => 'resolve_conversation',
        'conversation_id' => conversation.id,
        'conversation_display_id' => conversation.display_id,
        'status' => 'resolved',
        'reason' => 'Possible spam'
      )
      expect(Conversations::ActivityMessageJob).to have_been_enqueued.with(
        conversation,
        hash_including(
          account_id: account.id,
          inbox_id: inbox.id,
          message_type: :activity,
          content: "Conversation was marked resolved by #{assistant.name}: Possible spam"
        )
      )
    end

    it 'does not resolve without a specific completion explanation' do
      expect(tool.perform(tool_context)).to eq('A specific completion explanation is required')
      expect(conversation.reload).to be_open
    end

    it 'requires a specific explanation when the selected completion reason is other' do
      assistant.update!(
        config: assistant.config.merge(
          'outcome_reason_settings' => {
            'completion_reasons' => [{ 'id' => 'other', 'label' => 'Другое' }]
          }
        )
      )

      expect(tool.perform(tool_context, status_reason: 'other')).to eq('A specific completion explanation is required')
      expect(conversation.reload).to be_open
    end

    it 'rejects the generic other label as an explanation' do
      expect(tool.perform(tool_context, reason: 'Other', status_reason: 'other')).to eq(
        'A specific completion explanation is required'
      )
      expect(conversation.reload).to be_open
    end

    it 'records the concrete other explanation for analytics' do
      assistant.update!(
        config: assistant.config.merge(
          'outcome_reason_settings' => {
            'completion_reasons' => [{ 'id' => 'other', 'label' => 'Другое' }]
          }
        )
      )

      tool.perform(
        tool_context,
        status_reason: 'other',
        reason: 'Клиент завершил обращение нестандартным запросом'
      )

      expect(conversation.reload).to be_resolved
      expect(conversation.status_transitions.last.metadata).to include(
        'outcome_reason_id' => 'other',
        'outcome_reason_explanation' => 'Клиент завершил обращение нестандартным запросом'
      )
    end


    it 'creates a conversation_resolved reporting event' do
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)

      expect do
        perform_enqueued_jobs do
          tool.perform(tool_context, reason: 'Possible spam')
        end
      end.to change { ReportingEvent.where(conversation_id: conversation.id, name: 'conversation_resolved').count }.by(1)
    end
  end

  describe 'when auto-resolve is disabled for the account' do
    before { account.update!(captain_auto_resolve_mode: 'disabled') }

    it 'does not resolve and returns a disabled message' do
      result = tool.perform(tool_context, reason: 'Possible spam')

      expect(result).to eq('Auto-resolve is disabled for this account')
      expect(conversation.reload).not_to be_resolved
    end
  end

  describe 'when auto-resolve is disabled via legacy settings key' do
    before { account.update!(settings: account.settings.merge('captain_disable_auto_resolve' => true)) }

    it 'does not resolve and returns a disabled message' do
      result = tool.perform(tool_context, reason: 'Possible spam')

      expect(result).to eq('Auto-resolve is disabled for this account')
      expect(conversation.reload).not_to be_resolved
    end
  end

  describe 'resolving an already resolved conversation' do
    let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :resolved) }

    it 'does not re-resolve and returns an already resolved message' do
      queue_adapter = ActiveJob::Base.queue_adapter
      queue_adapter.enqueued_jobs.clear

      result = tool.perform(tool_context, reason: 'Possible spam')

      expect(result).to include('already resolved')
      expect(Conversations::ActivityMessageJob).not_to have_been_enqueued
    end
  end
end
