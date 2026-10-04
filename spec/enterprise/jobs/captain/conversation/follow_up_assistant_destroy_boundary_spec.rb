# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe 'Captain follow-up assistant deletion boundary', type: :job do
  self.use_transactional_tests = false

  let(:api_version) { 'v25.0' }

  before do
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v25.0').and_return(api_version)
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', '').and_return('')
  end

  after { CommittedRowsCleanup.truncate! }

  def in_thread(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&block)
    rescue StandardError => e
      e
    end
  end

  def materialized_follow_up
    channel = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      validate_provider_config: false,
      sync_templates: false
    )
    account = channel.account
    account.enable_features!('captain_integration')
    inbox = channel.inbox
    contact = create(:contact, account: account, phone_number: '+123456789')
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '123456789')
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )
    assistant = create(
      :captain_assistant,
      account: account,
      config: {
        'follow_up_settings' => {
          'enabled' => true,
          'prompt' => '',
          'steps' => [
            { 'mode' => 'static', 'message' => 'Checking in.', 'delay_seconds' => 60 },
            { 'mode' => 'static', 'message' => 'One more thought.', 'delay_seconds' => 120 }
          ]
        }
      }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    incoming = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      content: 'Can you help?'
    )
    anchor = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: assistant,
      message_type: :outgoing,
      private: false,
      additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
    )
    fence = {
      control_generation: conversation.current_captain_control_generation,
      status_transition_id: conversation.status_transitions.maximum(:id).to_i,
      last_message_id: incoming.id
    }
    reminder = Captain::Conversation::FollowUpJob.schedule!(
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor,
      step: { index: 0, delay_seconds: 60 },
      control_fence: fence
    )
    claim = reminder.mark_processing!
    message = Reminders::MessageMaterializer.new(
      reminder: reminder,
      additional_attributes: {
        'captain_follow_up' => {
          'assistant_id' => assistant.id,
          'anchor_message_id' => anchor.id,
          'step_index' => 0,
          'control_fence' => fence
        }
      }
    ).perform(
      conversation: conversation,
      sender: assistant,
      content: 'Checking in.',
      delivery_policy: nil
    )
    reminder.update!(status: :completed, completed_at: Time.current)

    [account, assistant, reminder, claim, message]
  end

  it 'waits for accepted Meta delivery and commits its sender ID and delivery marker before nullifying messages' do
    _account, assistant, reminder, claim, message = materialized_follow_up
    provider_entered = Queue.new
    release_provider = Queue.new
    request = stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
              .to_return do |_request|
                provider_entered << true
                Timeout.timeout(15) { release_provider.pop }
                {
                  status: 200,
                  body: { messages: [{ id: 'wamid.accepted-before-assistant-delete' }] }.to_json,
                  headers: { 'Content-Type' => 'application/json' }
                }
              end

    delivery_thread = in_thread do
      Reminders::DeliverMaterializedMessageJob.perform_now(reminder.id, message.id, claim)
    end
    Timeout.timeout(10) { provider_entered.pop }

    destroy_lock_attempted = Queue.new
    destroy_finished = Queue.new
    allow(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).and_wrap_original do |original, inbox_id|
      destroy_lock_attempted << inbox_id if Thread.current[:assistant_destroying]
      original.call(inbox_id)
    end
    destroy_thread = in_thread do
      Thread.current[:assistant_destroying] = true
      Captain::Assistant.find(assistant.id).destroy!
      destroy_finished << true
    end
    Timeout.timeout(10) { destroy_lock_attempted.pop }
    sleep 0.15
    expect(destroy_finished).to be_empty
    expect(destroy_thread).to be_alive

    release_provider << true
    results = [
      Timeout.timeout(20) { delivery_thread.value },
      Timeout.timeout(20) { destroy_thread.value }
    ]

    expect(results).to all(satisfy { |result| !result.is_a?(Exception) })
    expect(request).to have_been_made.once
    expect(Captain::Assistant.exists?(assistant.id)).to be(false)
    expect(message.reload.source_id).to eq('wamid.accepted-before-assistant-delete')
    expect(reminder.reload.delivery_stage).to eq('provider_accepted')
    expect(reminder.delivery_dispatched_for?(message.id)).to be(true)
  ensure
    release_provider << true if defined?(release_provider) && release_provider.empty?
    delivery_thread&.join(2)
    destroy_thread&.join(2)
  end
end
